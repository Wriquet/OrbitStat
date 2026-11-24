import AppKit
import SwiftUI

public struct PowerTabView: View {
    @ObservedObject public var store: MonitorStore

    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var isEnergyExpanded: Bool = false
    @ViewState private var hoveredEnergyAppID: String?

    public init(store: MonitorStore) {
        self.store = store
    }

    private var snapshot: PowerSnapshot? {
        store.powerSnapshot
    }

    private var labelSecondaryColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.68 : 0.58)
    }

    public var body: some View {
        let showBattery = store.settings.showPowerBatteryCard
        let showTemp = store.settings.showPowerTempRow
        let showHealth = store.settings.showPowerHealthRow
        let showSystem = store.settings.showPowerSystemCard
        let showAdapter = store.settings.showPowerAdapterRow

        VStack(alignment: .leading, spacing: 9) {
            // 1. 电池 Hero Glass Tile
            if showBattery {
                batteryHeroTile
            }

            // 2. 2-Column Bento Row (电池温度 + 电池健康度)
            if showTemp || showHealth {
                HStack(spacing: 9) {
                    if showTemp {
                        batteryTemperatureBentoTile
                    }
                    if showHealth {
                        batteryHealthBentoTile
                    }
                }
            }

            // 3. 系统功耗 Glass Tile
            if showSystem {
                systemPowerTile
            }

            // 4. 电源适配器 Glass Tile
            if showAdapter {
                adapterTile
            }

            if !showBattery && !showTemp && !showHealth && !showSystem && !showAdapter {
                GlassTile(cornerRadius: 20) {
                    Text("当前已隐藏全部电源模块，可点击右上角筛选按钮恢复。")
                        .font(.system(size: 12))
                        .foregroundStyle(labelSecondaryColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                        .padding(.horizontal, 14)
                }
            }
        }
    }

    // MARK: - 1. 电池 Hero Glass Tile

    private var batteryHeroTile: some View {
        let hasBattery = snapshot?.hasBattery ?? true
        let percent = hasBattery ? snapshot?.batteryPercent : nil
        let batteryColor = OrbitColors.batteryGreen(for: colorScheme)
        let energyApps = snapshot?.significantEnergyApps ?? []

        return GlassTile(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    MetricSymbolBadge(
                        systemImage: dynamicBatterySymbol,
                        color: batteryColor,
                        size: 30,
                        iconSize: 13.5,
                        muted: !hasBattery
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text("电池")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(batteryStatusSubtitle)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(labelSecondaryColor)
                    }

                    Spacer(minLength: 8)

                    Text(percent.map { MetricsFormatter.formatPercent($0) } ?? "--")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }

                ThinCapsuleBar(
                    progress: (percent ?? 0) / 100.0,
                    color: batteryColor,
                    height: 6.5
                )

                AreaSparklineChart(
                    values: store.batteryHistory,
                    color: batteryColor,
                    ceiling: .fixed(maxValue: 100, label: "100%"),
                    height: 42
                )

                // Expandable 显著耗能 row
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isEnergyExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(OrbitColors.thermalWarm(for: colorScheme))

                        Text("显著耗能")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.84))

                        if !energyApps.isEmpty {
                            StatusCapsulePill(
                                text: "\(energyApps.count)",
                                tint: OrbitColors.thermalWarm(for: colorScheme)
                            )
                        }

                        Spacer()

                        Image(systemName: isEnergyExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(labelSecondaryColor)
                    }
                    .padding(.top, 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isEnergyExpanded {
                    significantEnergyAppsView(apps: energyApps)
                        .transition(.opacity)
                }
            }
            .padding(11)
        }
    }

    private var dynamicBatterySymbol: String {
        guard let snapshot else { return "battery.100percent" }
        if !snapshot.hasBattery {
            return "powerplug.fill"
        }
        if snapshot.isCharging {
            return "battery.100percent.bolt"
        }
        if snapshot.isPluggedIn && !snapshot.isFullyCharged {
            return "battery.100percent.bolt"
        }
        switch snapshot.batteryPercent {
        case 88...100: return "battery.100percent"
        case 63..<88:  return "battery.75percent"
        case 38..<63:  return "battery.50percent"
        case 13..<38:  return "battery.25percent"
        default:       return "battery.0percent"
        }
    }

    private var batteryStatusSubtitle: String {
        guard let snapshot else { return "读取中…" }
        if !snapshot.hasBattery { return "无内置电池" }
        if snapshot.isFullyCharged { return "已充满" }
        if snapshot.isCharging { return "正在充电" }
        if snapshot.isPluggedIn { return "已连接电源" }
        return "使用电池供电"
    }

    @ViewBuilder
    private func significantEnergyAppsView(apps: [EnergyAppUsage]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

        if apps.isEmpty {
            Text("当前无显著耗能应用")
                .font(.system(size: 12))
                .foregroundStyle(labelSecondaryColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .background(
                    shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04))
                )
        } else {
            VStack(spacing: 2) {
                ForEach(apps) { app in
                    let isHovered = hoveredEnergyAppID == app.id
                    HStack(spacing: 8) {
                        Image(nsImage: store.icon(for: app))
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)

                        Text(app.name)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 8)

                        Text("CPU \(MetricsFormatter.formatDetailedPercent(app.cpuPercent))")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(labelSecondaryColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                isHovered
                                    ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.065)
                                    : Color.clear
                            )
                    )
                    .contentShape(Capsule(style: .continuous))
                    .onHover { hovering in
                        hoveredEnergyAppID = hovering ? app.id : (hoveredEnergyAppID == app.id ? nil : hoveredEnergyAppID)
                    }
                    .contextMenu {
                        if let bundlePath = app.bundlePath,
                           !bundlePath.isEmpty,
                           FileManager.default.fileExists(atPath: bundlePath) {
                            Button("在访达中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
                            }
                        }
                        Button("复制进程信息") {
                            copyEnergyProcessInfo(app)
                        }
                    }
                }
            }
            .padding(5)
            .background(
                shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04))
            )
            .clipShape(shape)
        }
    }

    // MARK: - 2A. 电池温度 Bento Tile

    private var batteryTemperatureBentoTile: some View {
        let celsius = snapshot?.batteryTemperatureCelsius
        let badgeColor: Color = {
            guard let c = celsius, c.isFinite else { return OrbitColors.thermalTeal(for: colorScheme) }
            if c >= 40 { return OrbitColors.thermalHot(for: colorScheme) }
            if c >= 35 { return OrbitColors.thermalWarm(for: colorScheme) }
            return OrbitColors.thermalTeal(for: colorScheme)
        }()
        let subtitle: String = {
            guard let c = celsius, c.isFinite else { return "暂无读数" }
            if c >= 40 { return "温度偏高" }
            if c >= 35 { return "略微温热" }
            return "温度正常"
        }()

        return GlassTile(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 6) {
                MetricSymbolBadge(
                    systemImage: "thermometer.medium",
                    color: badgeColor,
                    size: 26,
                    iconSize: 13
                )

                VStack(alignment: .leading, spacing: 1.5) {
                    Text("电池温度")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(labelSecondaryColor)

                    Text(MetricsFormatter.formatTemperature(celsius, unit: store.settings.temperatureUnit))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(labelSecondaryColor)
            }
            .padding(11)
        }
    }

    // MARK: - 2B. 电池健康度 Bento Tile

    private var batteryHealthBentoTile: some View {
        let heartColor = OrbitColors.healthMagenta(for: colorScheme)
        let cycleSubtitle: String = {
            if let cycles = snapshot?.cycleCount {
                return "\(cycles) 次循环"
            }
            return "-- 次循环"
        }()

        return GlassTile(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 6) {
                MetricSymbolBadge(
                    systemImage: "heart.fill",
                    color: heartColor,
                    size: 26,
                    iconSize: 12.5
                )

                VStack(alignment: .leading, spacing: 1.5) {
                    Text("电池健康度")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(labelSecondaryColor)

                    Text(MetricsFormatter.formatPercent(snapshot?.batteryHealthPercent))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Text(cycleSubtitle)
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(labelSecondaryColor)
            }
            .padding(11)
        }
    }

    // MARK: - 3. 系统功耗 Glass Tile

    private var systemPowerTile: some View {
        let powerColor = OrbitColors.systemPowerAmber(for: colorScheme)

        return GlassTile(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    MetricSymbolBadge(
                        systemImage: "bolt.fill",
                        color: powerColor,
                        size: 28,
                        iconSize: 13
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text("系统功耗")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("整机实时负载")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(labelSecondaryColor)
                    }

                    Spacer(minLength: 8)

                    Text(MetricsFormatter.formatWatts(snapshot?.systemPowerWatts, preferIntegerAboveTen: true))
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }

                AreaSparklineChart(
                    values: store.systemPowerHistory,
                    color: powerColor,
                    ceiling: .dynamicWatts(baseCap: 50, step: 50),
                    height: 43
                )
            }
            .padding(11)
        }
    }

    // MARK: - 4. 电源适配器 Glass Tile

    private var adapterTile: some View {
        let isPluggedIn = snapshot?.isPluggedIn ?? false
        let accentBlue = OrbitColors.accentBlue(for: colorScheme)

        return GlassTile(cornerRadius: 20) {
            HStack(alignment: .center, spacing: 10) {
                MetricSymbolBadge(
                    systemImage: "powerplug.fill",
                    color: accentBlue,
                    size: 28,
                    iconSize: 13,
                    muted: !isPluggedIn
                )

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(isPluggedIn ? "电源适配器" : "未连接电源")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(adapterSubtitle(isPluggedIn: isPluggedIn))
                        .font(.system(size: 11.5, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(labelSecondaryColor)
                }

                Spacer(minLength: 8)

                Text(isPluggedIn ? MetricsFormatter.formatWatts(snapshot?.adapterInputWatts, preferIntegerAboveTen: false) : "--")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isPluggedIn ? Color.primary : labelSecondaryColor)
            }
            .padding(11)
        }
    }

    private func adapterSubtitle(isPluggedIn: Bool) -> String {
        if isPluggedIn {
            if let maxW = snapshot?.adapterMaxWatts, maxW > 0 {
                return "最高 \(MetricsFormatter.formatWholeWatts(maxW))"
            }
            return "已连接外部电源"
        }
        return "使用电池供电"
    }

    // MARK: - Actions

    private func copyEnergyProcessInfo(_ app: EnergyAppUsage) {
        var lines = [
            "应用: \(app.name)",
            "PID: \(app.pid)",
            "CPU 占用: \(MetricsFormatter.formatDetailedPercent(app.cpuPercent))",
            "能耗影响: \(String(format: "%.1f", app.energyImpact))"
        ]
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
            lines.append("Bundle ID: \(bundleID)")
        }
        if let path = app.bundlePath, !path.isEmpty {
            lines.append("路径: \(path)")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
