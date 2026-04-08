import SwiftUI

/// 金手指调试页面
///
/// 用于测试人员手动覆盖健康数据，方便验证 UI 在各种数值下的表现。
/// 支持 push 和 present 两种方式打开。
///
/// ```swift
/// // push
/// NavigationLink("金手指") { StepsDebugView() }
///
/// // present
/// .sheet(isPresented: $showDebug) {
///     NavigationStack { StepsDebugView() }
/// }
/// ```
@MainActor
public struct StepsDebugView: View {

    @Bindable private var manager = StepsManager.shared
    @State private var steps: Double = 0
    @State private var activeEnergy: Double = 0
    @State private var distance: Double = 0
    @State private var exerciseTime: Double = 0

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("启用金手指", isOn: $manager.isDebugOverrideEnabled)
            } header: {
                Text("总开关")
            } footer: {
                Text("开启后，下方设置的数据将直接覆盖真实健康数据；关闭后自动恢复真实数据。")
            }

            if manager.isDebugOverrideEnabled {
                Section("数据设置") {
                    inputRow("步数", unit: "步", value: $steps)
                    inputRow("活动能量", unit: "千卡", value: $activeEnergy)
                    inputRow("步行跑步距离", unit: "米", value: $distance)
                    inputRow("锻炼时间", unit: "分钟", value: $exerciseTime)
                }

                Section {
                    Button("应用数据") {
                        manager.applyDebugValues(
                            steps: steps,
                            activeEnergy: activeEnergy,
                            distance: distance,
                            exerciseTime: exerciseTime
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            Section("当前数据（实时）") {
                dataRow("步数", value: manager.todaySteps, format: "%.0f 步")
                dataRow("活动能量", value: manager.todayActiveEnergy, format: "%.1f 千卡")
                dataRow("步行跑步距离", value: manager.todayDistance, format: "%.0f 米")
                dataRow("锻炼时间", value: manager.todayExerciseTime, format: "%.1f 分钟")
            }
        }
        .navigationTitle("金手指")
        .onAppear(perform: loadCurrentValues)
        .onChange(of: manager.isDebugOverrideEnabled) { _, enabled in
            if enabled {
                loadCurrentValues()
            } else {
                Task { await manager.disableDebugOverride() }
            }
        }
    }
}

// MARK: - 私有
private extension StepsDebugView {

    func loadCurrentValues() {
        steps = manager.todaySteps
        activeEnergy = manager.todayActiveEnergy
        distance = manager.todayDistance
        exerciseTime = manager.todayExerciseTime
    }

    func inputRow(_ title: String, unit: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
    }

    func dataRow(_ title: String, value: Double, format: String) -> some View {
        LabeledContent(title, value: String(format: format, value))
    }
}
