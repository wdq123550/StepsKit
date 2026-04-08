// The Swift Programming Language
// https://docs.swift.org/swift-book

import UIKit
import Foundation
import Observation
import HealthKit
import CoreMotion

// MARK: - 公开 · 埋点事件

/// 埋点事件
public enum StepsKitEvent: Sendable {
    /// 权限申请完成（CoreMotion 是否授权、HealthKit 申请是否成功）
    case authorizationCompleted(coreMotionGranted: Bool, healthKitCompleted: Bool)
    /// 开始监听
    case monitoringStarted
    /// 停止监听
    case monitoringStopped
    /// CoreMotion 不可用或出错，回退到 HealthKit 获取步数和距离
    case fallbackToHealthKit
    /// 跨天刷新触发
    case dayChanged
    /// 数据获取异常
    case error(Error, context: String)
}

// MARK: - 公开 · 埋点协议
/// 埋点协议
@MainActor
public protocol StepsKitTracker: AnyObject {
    func stepsKit(_ manager: StepsManager, didEmit event: StepsKitEvent)
}

// MARK: - 公开 · 错误类型
public enum StepsKitError: LocalizedError {
    case noData
    /// 尚未申请权限
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .noData:
            return "未获取到数据"
        case .notAuthorized:
            return "尚未申请权限，请先调用 requestAuthorization() 申请权限后再启动监听"
        }
    }
}

/// 健康数据管理器（单例）
///
/// 提供今日步数、活动能量、步行跑步距离、锻炼时间的获取与实时监听。
/// 步数与距离优先从 CoreMotion 获取，失败时回退到 HealthKit；
/// 活动能量与锻炼时间仅通过 HealthKit 获取。
///
/// ## Info.plist 配置（请复制以下 Key 到 Info.plist）
/// ```
/// NSMotionUsageDescription
/// NSHealthShareUsageDescription
/// NSHealthUpdateUsageDescription
/// ```
///
/// ## Capability
/// 需要在 Xcode → Signing & Capabilities 中添加 **HealthKit**。
///
/// ## 注意事项
/// 1. 权限必须通过 ``requestAuthorization()`` 一次性申请，不支持单独申请 CoreMotion 或 HealthKit。
///    内部会按 **CoreMotion → HealthKit** 的顺序依次弹出系统授权弹窗。
///    即使用户拒绝了 CoreMotion 权限，也不影响后续 HealthKit 权限的申请。
/// 2. 必须先调用 ``requestAuthorization()`` 再调用 ``startMonitoring()``，
///    否则 `startMonitoring()` 会抛出 `StepsKitError.notAuthorized` 错误。
///    是否已申请过权限可通过 ``hasRequestedAuthorization`` 判断（基于 UserDefaults 持久化）。
/// 3. 调用 ``startMonitoring()`` 后，框架会自动持续监听并更新以下存储属性，外界直接读取即可：
///    - ``todaySteps`` — 今日步数（步）
///    - ``todayActiveEnergy`` — 今日活动能量消耗（千卡, kcal）
///    - ``todayDistance`` — 今日步行+跑步距离（米, m）
///    - ``todayExerciseTime`` — 今日锻炼时间（分钟, min）
/// 4. 类遵循 `@Observable`，上述属性变化时 SwiftUI 视图会自动刷新。
/// 5. 不再需要监听时调用 ``stopMonitoring()`` 释放资源。
/// 6. 框架内置跨天自动刷新，无论是自然午夜跨天还是测试人员修改系统时间，
///    回到前台后都会自动重置并获取新一天的数据。
///
/// ## 使用示例
/// ```swift
/// struct ContentView: View {
///     let manager = StepsManager.shared
///
///     var body: some View {
///         VStack {
///             Text("步数: \(manager.todaySteps, format: .number)")
///             Text("能量: \(manager.todayActiveEnergy, format: .number) kcal")
///             Text("距离: \(manager.todayDistance, format: .number) m")
///             Text("锻炼: \(manager.todayExerciseTime, format: .number) min")
///         }
///         .task {
///             if !manager.hasRequestedAuthorization {
///                 try? await manager.requestAuthorization()
///             }
///             try? await manager.startMonitoring()
///         }
///     }
/// }
/// ```
@MainActor @Observable
public final class StepsManager {

    private init() {}
    public static let shared = StepsManager()

    // MARK: - 公开属性

    /// 今日步数（步）
    public private(set) var todaySteps: Double = 0

    /// 今日活动能量消耗（千卡, kcal）
    public private(set) var todayActiveEnergy: Double = 0

    /// 今日步行+跑步距离（米, m）
    public private(set) var todayDistance: Double = 0

    /// 今日锻炼时间（分钟, min）
    public private(set) var todayExerciseTime: Double = 0

    /// 是否正在监听
    public private(set) var isMonitoring = false

    /// 埋点代理，外界实现 ``StepsKitTracker`` 协议后赋值即可接收事件
    public weak var tracker: (any StepsKitTracker)?

    /// 金手指总开关（非持久化，App 重启后自动关闭，对外通过 StepsDebugView 操作）
    internal var isDebugOverrideEnabled = false

    // MARK: - 私有属性

    private let pedometer = CMPedometer()
    private let healthStore = HKHealthStore()
    @ObservationIgnored private var healthKitQueries: [HKObserverQuery] = []
    @ObservationIgnored private var useHealthKitForSteps = false
    @ObservationIgnored private var currentDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var dayChangeObservers: [NSObjectProtocol] = []
    private static let authorizationRequestedKey = "StepsKit.authorizationRequested"
}

// MARK: - 公开计算属性
public extension StepsManager {

    /// 是否已申请过权限（基于 UserDefaults 标识）
    var hasRequestedAuthorization: Bool {
        UserDefaults.standard.bool(forKey: Self.authorizationRequestedKey)
    }

    /// CoreMotion 计步器授权状态
    var coreMotionAuthorizationStatus: CMAuthorizationStatus {
        CMPedometer.authorizationStatus()
    }
}

// MARK: - 公开方法
public extension StepsManager {

    /// 一键申请所有权限（CoreMotion → HealthKit）
    ///
    /// 依次申请 CoreMotion 和 HealthKit 权限。
    /// CoreMotion 即使被用户拒绝也不影响后续 HealthKit 权限申请。
    /// 全部完成后在 UserDefaults 中记录标识，供 `startMonitoring()` 检查。
    func requestAuthorization() async throws {
        var coreMotionGranted = false
        do {
            try await requestCoreMotionAuthorization()
            coreMotionGranted = true
        } catch {}

        var healthKitCompleted = false
        do {
            try await requestHealthKitAuthorization()
            healthKitCompleted = true
        } catch {
            tracker?.stepsKit(self, didEmit: .error(error, context: "requestHealthKitAuthorization"))
            throw error
        }

        UserDefaults.standard.set(true, forKey: Self.authorizationRequestedKey)
        tracker?.stepsKit(self, didEmit: .authorizationCompleted(
            coreMotionGranted: coreMotionGranted,
            healthKitCompleted: healthKitCompleted
        ))
    }

    /// 一键启动监听
    ///
    /// 先获取今日全部数据，然后开启实时监听：
    /// - CoreMotion 实时更新步数与距离（不可用或出错时自动回退 HealthKit Observer）
    /// - HealthKit Observer 监听活动能量与锻炼时间变化
    ///
    /// - Throws: `StepsKitError.notAuthorized` — 尚未调用 `requestAuthorization()` 申请权限
    func startMonitoring() async throws {
        guard hasRequestedAuthorization else {
            throw StepsKitError.notAuthorized
        }
        guard !isMonitoring else { return }

        currentDay = Calendar.current.startOfDay(for: Date())
        await fetchTodayData()
        startPedometerUpdates()
        startHealthKitObservers()
        startDayChangeListeners()
        isMonitoring = true
        tracker?.stepsKit(self, didEmit: .monitoringStarted)
    }

    /// 停止监听
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        pedometer.stopUpdates()
        for query in healthKitQueries {
            healthStore.stop(query)
        }
        healthKitQueries.removeAll()
        useHealthKitForSteps = false
        stopDayChangeListeners()
        tracker?.stepsKit(self, didEmit: .monitoringStopped)
    }
}

// MARK: - 金手指（internal，对外通过 StepsDebugView 使用）
internal extension StepsManager {

    // 覆盖存储属性为金手指数据
    func applyDebugValues(
        steps: Double,
        activeEnergy: Double,
        distance: Double,
        exerciseTime: Double
    ) {
        guard isDebugOverrideEnabled else { return }
        todaySteps = steps
        todayActiveEnergy = activeEnergy
        todayDistance = distance
        todayExerciseTime = exerciseTime
    }

    // 关闭金手指并恢复真实数据
    func disableDebugOverride() async {
        isDebugOverrideEnabled = false
        guard isMonitoring else { return }
        await fetchTodayData()
    }
}


// MARK: - 私有 · 权限申请
private extension StepsManager {

    // CoreMotion 通过一次计步器查询触发系统授权弹窗
    func requestCoreMotionAuthorization() async throws {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pedometer.queryPedometerData(from: start, to: now) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // 请求 HealthKit 读取权限
    func requestHealthKitAuthorization() async throws {
        let types: Set<HKSampleType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.appleExerciseTime)
        ]
        try await healthStore.requestAuthorization(toShare: [], read: types)
    }
}

// MARK: - 私有 · 数据获取
private extension StepsManager {

    // 并发获取今日所有健康数据
    func fetchTodayData() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetchStepsAndDistance() }
            group.addTask { await self.fetchActiveEnergy() }
            group.addTask { await self.fetchExerciseTime() }
        }
    }

    // CoreMotion 优先，失败后回退 HealthKit
    func fetchStepsAndDistance() async {
        guard !isDebugOverrideEnabled else { return }
        if CMPedometer.isStepCountingAvailable() {
            do {
                let data = try await queryPedometerData()
                todaySteps = data.numberOfSteps.doubleValue
                todayDistance = data.distance?.doubleValue ?? 0
                return
            } catch {}
        }
        async let steps = queryHealthKit(.stepCount, unit: .count())
        async let distance = queryHealthKit(.distanceWalkingRunning, unit: .meter())
        todaySteps = await steps
        todayDistance = await distance
    }

    // 获取今日活动能量
    func fetchActiveEnergy() async {
        guard !isDebugOverrideEnabled else { return }
        todayActiveEnergy = await queryHealthKit(.activeEnergyBurned, unit: .kilocalorie())
    }

    // 获取今日锻炼时间
    func fetchExerciseTime() async {
        guard !isDebugOverrideEnabled else { return }
        todayExerciseTime = await queryHealthKit(.appleExerciseTime, unit: .minute())
    }
}

// MARK: - 私有 · 实时监听
private extension StepsManager {

    // 启动 CoreMotion 计步器实时更新
    func startPedometerUpdates() {
        guard CMPedometer.isStepCountingAvailable() else {
            fallbackToHealthKitForSteps()
            return
        }
        let start = Calendar.current.startOfDay(for: Date())
        pedometer.startUpdates(from: start) { data, error in
            Task { @MainActor in
                guard !self.isDebugOverrideEnabled else { return }
                if let data, error == nil {
                    self.todaySteps = data.numberOfSteps.doubleValue
                    self.todayDistance = data.distance?.doubleValue ?? 0
                } else if !self.useHealthKitForSteps {
                    self.pedometer.stopUpdates()
                    self.fallbackToHealthKitForSteps()
                }
            }
        }
    }

    // CoreMotion 不可用时回退到 HealthKit 监听步数和距离
    func fallbackToHealthKitForSteps() {
        useHealthKitForSteps = true
        observeHealthKit(.stepCount, unit: .count())
        observeHealthKit(.distanceWalkingRunning, unit: .meter())
        tracker?.stepsKit(self, didEmit: .fallbackToHealthKit)
    }

    // 启动 HealthKit 活动能量和锻炼时间的 Observer
    func startHealthKitObservers() {
        observeHealthKit(.activeEnergyBurned, unit: .kilocalorie())
        observeHealthKit(.appleExerciseTime, unit: .minute())
    }

    // 为指定 HealthKit 类型创建 ObserverQuery 持续监听变化
    func observeHealthKit(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) {
        let type = HKQuantityType(identifier)
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
            guard error == nil else {
                completionHandler()
                return
            }
            Task { @MainActor in
                let value = await self.queryHealthKit(identifier, unit: unit)
                self.applyHealthKitValue(value, for: identifier)
                completionHandler()
            }
        }
        healthKitQueries.append(query)
        healthStore.execute(query)
    }

    // 将 HealthKit 查询结果写入对应的存储属性
    func applyHealthKitValue(_ value: Double, for identifier: HKQuantityTypeIdentifier) {
        guard !isDebugOverrideEnabled else { return }
        if identifier == .activeEnergyBurned {
            todayActiveEnergy = value
        } else if identifier == .appleExerciseTime {
            todayExerciseTime = value
        } else if identifier == .stepCount {
            todaySteps = value
        } else if identifier == .distanceWalkingRunning {
            todayDistance = value
        }
    }
}

// MARK: - 私有 · 跨天刷新
private extension StepsManager {

    // NSCalendarDayChanged: 前台自然跨过午夜
    // didBecomeActiveNotification: 后台回前台（含测试人员改系统时间）
    func startDayChangeListeners() {
        let calendarObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await self.handleDayChangeIfNeeded() }
        }
        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await self.handleDayChangeIfNeeded() }
        }
        dayChangeObservers = [calendarObserver, foregroundObserver]
    }

    // 移除所有跨天监听
    func stopDayChangeListeners() {
        for observer in dayChangeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        dayChangeObservers.removeAll()
    }

    // 检测是否跨天，若跨天则重置数据并重新启动监听
    func handleDayChangeIfNeeded() async {
        let newDay = Calendar.current.startOfDay(for: Date())
        guard newDay != currentDay else { return }
        currentDay = newDay
        tracker?.stepsKit(self, didEmit: .dayChanged)

        todaySteps = 0
        todayActiveEnergy = 0
        todayDistance = 0
        todayExerciseTime = 0

        pedometer.stopUpdates()
        for query in healthKitQueries {
            healthStore.stop(query)
        }
        healthKitQueries.removeAll()
        useHealthKitForSteps = false

        await fetchTodayData()
        startPedometerUpdates()
        startHealthKitObservers()
    }
}

// MARK: - 私有 · 底层查询
private extension StepsManager {

    // 查询今日 CoreMotion 计步器数据
    func queryPedometerData() async throws -> CMPedometerData {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        do {
            return try await withCheckedThrowingContinuation { continuation in
                pedometer.queryPedometerData(from: start, to: now) { data, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: StepsKitError.noData)
                    }
                }
            }
        } catch {
            tracker?.stepsKit(self, didEmit: .error(error, context: "queryPedometerData"))
            throw error
        }
    }

    // 查询今日指定 HealthKit 类型的累计值
    func queryHealthKit(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double {
        let quantityType = HKQuantityType(identifier)
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: quantityType, predicate: predicate),
            options: .cumulativeSum
        )
        do {
            let result = try await descriptor.result(for: healthStore)
            return result?.sumQuantity()?.doubleValue(for: unit) ?? 0
        } catch {
            tracker?.stepsKit(self, didEmit: .error(error, context: "queryHealthKit(\(identifier))"))
            return 0
        }
    }
}
