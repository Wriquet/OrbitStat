import SwiftUI

public struct SettingsView: View {
    @ObservedObject public var store: MonitorStore
    public var onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let refreshIntervals: [Double] = [1.0, 2.0, 3.0, 5.0]
    private static let memoryAppLimits: [Int] = [5, 10, 15, 20]

    public init(store: MonitorStore, onBack: @escaping () -> Void) {
        self.store = store
        self.onBack = onBack
    }

    private var labelSecondaryColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.68 : 0.58)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Pinned at very top — official 28pt glass capsules
            headerBar
                .padding(.horizontal, 14)
                .padding(.top, 14)

            // Top-aligned scrollable official .glassEffect settings tiles
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // Tile 1: 通用监测设置
                    GlassTile(cornerRadius: 20) {
                        VStack(alignment: .leading, spacing: 11) {
                            segmentedSettingRow(title: "刷新间隔") {
                                Picker("刷新间隔", selection: $store.settings.refreshIntervalSeconds) {
                                    ForEach(Self.refreshIntervals, id: \.self) { sec in
                                        Text("\(Int(sec))s").tag(sec)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                            }

                            CardDivider()

                            segmentedSettingRow(title: "温度单位") {
                                Picker("温度单位", selection: $store.settings.temperatureUnit) {
                                    ForEach(TemperatureUnit.allCases) { unit in
                                        Text(unit.symbol).tag(unit)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                            }

                            CardDivider()

                            segmentedSettingRow(title: "内存列表显示数量") {
                                Picker("内存列表显示数量", selection: $store.settings.maxMemoryApps) {
                                    ForEach(Self.memoryAppLimits, id: \.self) { count in
                                        Text("\(count)").tag(count)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                            }
                        }
                        .padding(13)
                    }

                    // Tile 2: 菜单栏实时显示 (header inside the glass tile so it stays readable over any desktop!)
                    GlassTile(cornerRadius: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("菜单栏实时显示")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(labelSecondaryColor)

                            toggleRow(title: "显示 CPU 占用", isOn: $store.settings.showMenuBarCPU)
                            CardDivider()
                            toggleRow(title: "显示 CPU 温度", isOn: $store.settings.showMenuBarTemp)
                            CardDivider()
                            toggleRow(title: "显示电池电量", isOn: $store.settings.showMenuBarBattery)
                            CardDivider()
                            toggleRow(title: "显示系统功耗", isOn: $store.settings.showMenuBarPower)
                        }
                        .padding(13)
                    }

                    // Tile 3: 系统启动
                    GlassTile(cornerRadius: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            toggleRow(title: "开机自动启动", isOn: $store.settings.launchAtLogin)

                            if let error = store.launchAtLoginError, !error.isEmpty {
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(labelSecondaryColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(13)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Anchored cleanly at bottom as an official 28pt glass capsule
            HStack {
                Spacer()
                NativeGlassCapsulePill(
                    text: "OrbitStat 1.0",
                    systemImage: "gauge.with.dots.needle.33percent",
                    height: 28
                )
                Spacer()
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        LiquidGlassGroup(spacing: 8) {
            ZStack {
                HStack {
                    NativeCapsuleButton(
                        title: "返回",
                        systemImage: "chevron.left",
                        compact: true,
                        action: onBack
                    )
                    Spacer()
                }

                NativeGlassCapsulePill(text: "设置", height: 28)
            }
        }
    }

    // MARK: - Reusable Setting Rows

    private func segmentedSettingRow<Control: View>(
        title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.90))
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            control()
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.90))

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
