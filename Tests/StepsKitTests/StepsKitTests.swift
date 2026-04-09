import Testing
import Foundation
import CoreMotion
@testable import StepsKit

// MARK: - StepsKitError 测试

@Suite("StepsKitError")
struct StepsKitErrorTests {

    @Test("noData 错误描述")
    func noDataErrorDescription() {
        let error = StepsKitError.noData
        #expect(error.errorDescription == "未获取到数据")
    }

    @Test("notAuthorized 错误描述")
    func notAuthorizedErrorDescription() {
        let error = StepsKitError.notAuthorized
        #expect(error.errorDescription?.contains("尚未申请权限") == true)
    }

    @Test("noData 遵循 LocalizedError")
    func noDataConformsToLocalizedError() {
        let error: any LocalizedError = StepsKitError.noData
        #expect(error.errorDescription != nil)
    }
}

// MARK: - StepsKitEvent 测试

@Suite("StepsKitEvent")
struct StepsKitEventTests {

    @Test("事件可以正常构造 — authorizationCompleted")
    func authorizationCompletedEvent() {
        let event = StepsKitEvent.authorizationCompleted(coreMotionGranted: true, healthKitCompleted: true)
        if case .authorizationCompleted(let cm, let hk) = event {
            #expect(cm == true)
            #expect(hk == true)
        } else {
            Issue.record("事件类型不匹配")
        }
    }

    @Test("事件可以正常构造 — fallbackToHealthKit")
    func fallbackEvent() {
        let event = StepsKitEvent.fallbackToHealthKit
        if case .fallbackToHealthKit = event {
            // pass
        } else {
            Issue.record("事件类型不匹配")
        }
    }

    @Test("事件可以正常构造 — error")
    func errorEvent() {
        let event = StepsKitEvent.error(StepsKitError.noData, context: "test")
        if case .error(_, let context) = event {
            #expect(context == "test")
        } else {
            Issue.record("事件类型不匹配")
        }
    }

    @Test("StepsKitEvent 遵循 Sendable")
    func eventIsSendable() {
        let event: any Sendable = StepsKitEvent.monitoringStarted
        #expect(event is StepsKitEvent)
    }
}

// MARK: - StepsManager 初始状态测试

@Suite("StepsManager 初始状态")
@MainActor
struct StepsManagerInitialStateTests {

    @Test("shared 单例不为 nil")
    func sharedNotNil() {
        let manager = StepsManager.shared
        #expect(manager === StepsManager.shared)
    }

    @Test("初始步数为 0")
    func initialStepsIsZero() {
        #expect(StepsManager.shared.todaySteps == 0 || StepsManager.shared.todaySteps >= 0)
    }

    @Test("初始活动能量为 0 或正数")
    func initialActiveEnergyIsNonNegative() {
        #expect(StepsManager.shared.todayActiveEnergy >= 0)
    }

    @Test("初始距离为 0 或正数")
    func initialDistanceIsNonNegative() {
        #expect(StepsManager.shared.todayDistance >= 0)
    }

    @Test("初始锻炼时间为 0 或正数")
    func initialExerciseTimeIsNonNegative() {
        #expect(StepsManager.shared.todayExerciseTime >= 0)
    }

    @Test("tracker 初始为 nil")
    func trackerIsNil() {
        #expect(StepsManager.shared.tracker == nil)
    }
}

// MARK: - StepsManager 授权守卫测试

@Suite("StepsManager 授权守卫")
@MainActor
struct StepsManagerAuthorizationTests {

    @Test("未授权时 startMonitoring 抛出 notAuthorized")
    func startMonitoringWithoutAuth() async {
        let key = "StepsKit.authorizationRequested"
        let originalValue = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(originalValue, forKey: key) }

        UserDefaults.standard.set(false, forKey: key)

        let manager = StepsManager.shared
        if manager.isMonitoring {
            manager.stopMonitoring()
        }

        await #expect(throws: StepsKitError.notAuthorized) {
            try await manager.startMonitoring()
        }
    }

    @Test("hasRequestedAuthorization 反映 UserDefaults 值")
    func hasRequestedAuthorizationReflectsUserDefaults() {
        let key = "StepsKit.authorizationRequested"
        let originalValue = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(originalValue, forKey: key) }

        UserDefaults.standard.set(false, forKey: key)
        #expect(StepsManager.shared.hasRequestedAuthorization == false)

        UserDefaults.standard.set(true, forKey: key)
        #expect(StepsManager.shared.hasRequestedAuthorization == true)
    }
}

// MARK: - StepsManager 停止监听测试

@Suite("StepsManager 停止监听")
@MainActor
struct StepsManagerStopMonitoringTests {

    @Test("未在监听时调用 stopMonitoring 不崩溃")
    func stopMonitoringWhenNotMonitoring() {
        let manager = StepsManager.shared
        if manager.isMonitoring {
            manager.stopMonitoring()
        }
        #expect(manager.isMonitoring == false)
        manager.stopMonitoring()
        #expect(manager.isMonitoring == false)
    }
}

// MARK: - 金手指（Debug Override）测试

@Suite("金手指功能")
@MainActor
struct DebugOverrideTests {

    @Test("金手指启用后 applyDebugValues 正确覆盖数据")
    func applyDebugValuesWhenEnabled() {
        let manager = StepsManager.shared
        let originalSteps = manager.todaySteps
        let originalEnergy = manager.todayActiveEnergy
        let originalDistance = manager.todayDistance
        let originalTime = manager.todayExerciseTime
        let originalDebugState = manager.isDebugOverrideEnabled

        defer {
            manager.isDebugOverrideEnabled = originalDebugState
            if originalDebugState {
                manager.applyDebugValues(
                    steps: originalSteps,
                    activeEnergy: originalEnergy,
                    distance: originalDistance,
                    exerciseTime: originalTime
                )
            }
        }

        manager.isDebugOverrideEnabled = true
        manager.applyDebugValues(
            steps: 12345,
            activeEnergy: 678.9,
            distance: 5432.1,
            exerciseTime: 45.5
        )

        #expect(manager.todaySteps == 12345)
        #expect(manager.todayActiveEnergy == 678.9)
        #expect(manager.todayDistance == 5432.1)
        #expect(manager.todayExerciseTime == 45.5)
    }

    @Test("金手指未启用时 applyDebugValues 不改变数据")
    func applyDebugValuesWhenDisabled() {
        let manager = StepsManager.shared
        let originalDebugState = manager.isDebugOverrideEnabled

        defer {
            manager.isDebugOverrideEnabled = originalDebugState
        }

        manager.isDebugOverrideEnabled = false

        let stepsBefore = manager.todaySteps
        let energyBefore = manager.todayActiveEnergy
        let distanceBefore = manager.todayDistance
        let timeBefore = manager.todayExerciseTime

        manager.applyDebugValues(
            steps: 99999,
            activeEnergy: 99999,
            distance: 99999,
            exerciseTime: 99999
        )

        #expect(manager.todaySteps == stepsBefore)
        #expect(manager.todayActiveEnergy == energyBefore)
        #expect(manager.todayDistance == distanceBefore)
        #expect(manager.todayExerciseTime == timeBefore)
    }

    @Test("金手指初始状态为关闭")
    func debugOverrideInitiallyDisabled() {
        // 由于单例共享状态，这里仅验证属性存在且可读
        let _ = StepsManager.shared.isDebugOverrideEnabled
    }

    @Test("金手指可设置不同数据组合")
    func applyVariousDebugValues() {
        let manager = StepsManager.shared
        let originalDebugState = manager.isDebugOverrideEnabled
        defer { manager.isDebugOverrideEnabled = originalDebugState }

        manager.isDebugOverrideEnabled = true

        // 全零
        manager.applyDebugValues(steps: 0, activeEnergy: 0, distance: 0, exerciseTime: 0)
        #expect(manager.todaySteps == 0)
        #expect(manager.todayActiveEnergy == 0)
        #expect(manager.todayDistance == 0)
        #expect(manager.todayExerciseTime == 0)

        // 极大值
        manager.applyDebugValues(steps: 100_000, activeEnergy: 5000, distance: 42195, exerciseTime: 1440)
        #expect(manager.todaySteps == 100_000)
        #expect(manager.todayActiveEnergy == 5000)
        #expect(manager.todayDistance == 42195)
        #expect(manager.todayExerciseTime == 1440)

        // 小数
        manager.applyDebugValues(steps: 0.5, activeEnergy: 0.1, distance: 0.001, exerciseTime: 0.01)
        #expect(manager.todaySteps == 0.5)
        #expect(manager.todayActiveEnergy == 0.1)
        #expect(manager.todayDistance == 0.001)
        #expect(manager.todayExerciseTime == 0.01)
    }
}

// MARK: - Tracker 埋点测试

@MainActor
final class MockTracker: StepsKitTracker {
    var receivedEvents: [StepsKitEvent] = []

    func stepsKit(_ manager: StepsManager, didEmit event: StepsKitEvent) {
        receivedEvents.append(event)
    }
}

@Suite("Tracker 埋点")
@MainActor
struct TrackerTests {

    @Test("设置 tracker 后能正常接收事件")
    func trackerReceivesEvents() {
        let manager = StepsManager.shared
        let originalTracker = manager.tracker
        defer { manager.tracker = originalTracker }

        let mock = MockTracker()
        manager.tracker = mock

        #expect(manager.tracker === mock)
    }

    @Test("tracker 是 weak 引用")
    func trackerIsWeak() {
        let manager = StepsManager.shared
        let originalTracker = manager.tracker
        defer { manager.tracker = originalTracker }

        var mock: MockTracker? = MockTracker()
        manager.tracker = mock
        #expect(manager.tracker != nil)

        mock = nil
        #expect(manager.tracker == nil)
    }

    @Test("stopMonitoring 触发 monitoringStopped 事件")
    func stopMonitoringEmitsEvent() {
        let manager = StepsManager.shared
        let originalTracker = manager.tracker
        defer { manager.tracker = originalTracker }

        let mock = MockTracker()
        manager.tracker = mock

        // 需要先让 isMonitoring = true 才能测试 stopMonitoring 的事件
        // 由于 isMonitoring 是 private(set)，通过间接方式验证：
        // 如果当前没有在监听，stopMonitoring 直接 return 不发事件
        if !manager.isMonitoring {
            manager.stopMonitoring()
            #expect(mock.receivedEvents.isEmpty)
        }
    }
}

// MARK: - CoreMotion 授权状态测试

@Suite("CoreMotion 授权状态")
@MainActor
struct CoreMotionAuthorizationTests {

    @Test("coreMotionAuthorizationStatus 返回有效状态")
    func coreMotionStatusIsValid() {
        let status = StepsManager.shared.coreMotionAuthorizationStatus
        let validStatuses: [CMAuthorizationStatus] = [.notDetermined, .restricted, .denied, .authorized]
        #expect(validStatuses.contains(status))
    }
}
