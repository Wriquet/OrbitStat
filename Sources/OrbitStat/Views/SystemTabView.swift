import AppKit
import SwiftUI

public struct SystemTabView: View {
    @ObservedObject public var store: MonitorStore

    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var hoveredAppID: String?

    public init(store: MonitorStore) {
        self.store = store
    }

    private var snapshot: SystemSnapshot? {
        store.systemSnapshot
    }

    private var labelSecondaryColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.68 : 0.58)
    }

    public var body: some View {
        let showCPU = store.settings.showSystemCPUCard
        let showTemp = store.settings.showSystemTempCard
        let showMemory = store.settings.showSystemMemoryCard

        VStack(alignment: .leading, spacing: 10) {
            // 1. Top 2-Column Control Center Bento Row (CPU % + CPU 温度)
            if showCPU || showTemp {
                HStack(spacing: 10) {
                    if showCPU {
                        cpuHeroBentoTile
                    }
                    if showTemp {
                        temperatureBentoTile
                    }
                }
            }

            // 2. CPU 实时趋势 Tile
            if showCPU {
                cpuTrendTile
            }

            // 3. 内存 Glass Tile
            if showMemory {
                memoryTile
            }

            if !showCPU && !showTemp && !showMemory {
                GlassTile(cornerRadius: 20) {
                    Text("当前已隐藏全部系统模块，可点击右上角筛选按钮恢复。")
                        .font(.system(size: 12))
                        .foregroundStyle(labelSecondaryColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                        .padding(.horizontal, 14)
                }
            }
        }
    }

    // MARK: - 1A. CPU Hero Bento Tile

    private var cpuHeroBentoTile: some View {
        let accentBlue = OrbitColors.accentBlue(for: colorScheme)
        let usageText = snapshot.map { MetricsFormatter.formatPercent($0.cpuTotalUsage) } ?? "-"

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                store.isCPUExpanded.toggle()
            }
        } label: {
            GlassTile(cornerRadius: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        MetricSymbolBadge(
                            systemImage: "cpu",
                            color: accentBlue,
                            size: 28,
                            iconSize: 13.5
                        )
                        Spacer()
                        Image(systemName: store.isCPUExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(labelSecondaryColor)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055))
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CPU")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(labelSecondaryColor)

                        Text(usageText)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    ThinCapsuleBar(
                        progress: (snapshot?.cpuTotalUsage ?? 0) / 100.0,
                        color: accentBlue,
                        height: 6
                    )
                }
                .padding(13)
            }
        }
        .buttonStyle(LiquidGlassPressStyle())
    }

    // MARK: - 1B. CPU 温度 Bento Tile

    private var temperatureBentoTile: some View {
        let celsius = snapshot?.cpuTemperatureCelsius
        let thermal = thermalDescriptor(for: celsius)
        let normalizedTemp: Double = {
            guard let c = celsius, c.isFinite else { return 0 }
            return min(1.0, max(0.0, (c - 20.0) / 80.0))
        }()

        return GlassTile(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    MetricSymbolBadge(
                        systemImage: "thermometer.medium",
                        color: thermal.color,
                        size: 28,
                        iconSize: 13.5
                    )
                    Spacer(minLength: 4)
                    StatusCapsulePill(text: thermal.label, tint: thermal.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU 温度")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(labelSecondaryColor)

                    Text(MetricsFormatter.formatTemperature(celsius, unit: store.settings.temperatureUnit))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                ThinCapsuleBar(
                    progress: normalizedTemp,
                    color: thermal.color,
                    height: 6
                )
            }
            .padding(13)
        }
    }

    private func thermalDescriptor(for celsius: Double?) -> (label: String, color: Color) {
        guard let c = celsius, c.isFinite else {
            return ("--", OrbitColors.thermalTeal(for: colorScheme))
        }
        if c < 55 {
            return ("正常", OrbitColors.thermalTeal(for: colorScheme))
        } else if c < 75 {
            return ("温热", OrbitColors.thermalWarm(for: colorScheme))
        } else {
            return ("偏高", OrbitColors.thermalHot(for: colorScheme))
        }
    }

    // MARK: - 2. CPU 实时趋势 Tile

    private var cpuTrendTile: some View {
        let accentBlue = OrbitColors.accentBlue(for: colorScheme)

        return GlassTile(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentBlue)

                    Text("处理器占用")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 6)

                    HStack(spacing: 6) {
                        TileInlineCapsuleButton(
                            title: store.isCPUExpanded ? "收起" : "详情",
                            systemImage: store.isCPUExpanded ? "chevron.up" : "chevron.down"
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                store.isCPUExpanded.toggle()
                            }
                        }

                        TileInlineCircleButton(
                            systemImage: "arrow.up.right",
                            size: 24,
                            iconSize: 10.5,
                            help: "打开活动监视器",
                            action: openActivityMonitor
                        )
                    }
                }

                AreaSparklineChart(
                    values: store.cpuHistory,
                    color: accentBlue,
                    ceiling: .fixed(maxValue: 100, label: "100%"),
                    height: 50
                )

                if store.isCPUExpanded, let snapshot {
                    cpuDetailBreakdown(snapshot: snapshot, accent: accentBlue)
                        .transition(.opacity)
                }
            }
            .padding(13)
        }
    }

    private func cpuDetailBreakdown(snapshot: SystemSnapshot, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                miniMetricCapsule(title: "用户", value: MetricsFormatter.formatDetailedPercent(snapshot.cpuUserUsage))
                miniMetricCapsule(title: "系统", value: MetricsFormatter.formatDetailedPercent(snapshot.cpuSystemUsage))
                miniMetricCapsule(title: "空闲", value: MetricsFormatter.formatDetailedPercent(snapshot.cpuIdleUsage))
            }

            if !snapshot.perCoreUsage.isEmpty {
                let columns = [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ]
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(snapshot.perCoreUsage) { core in
                        HStack(spacing: 5) {
                            Text(coreLabel(for: core))
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(labelSecondaryColor)
                                .frame(width: 24, alignment: .leading)

                            ThinCapsuleBar(
                                progress: core.usage / 100.0,
                                color: accent.opacity(core.isPerformanceCore == false ? 0.65 : 1.0),
                                height: 4.5
                            )

                            Text(MetricsFormatter.formatPercent(core.usage))
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(labelSecondaryColor)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func coreLabel(for core: CoreUsage) -> String {
        if let isP = core.isPerformanceCore {
            return isP ? "P\(core.id + 1)" : "E\(core.id + 1)"
        }
        return "C\(core.id + 1)"
    }

    // MARK: - 3. 内存 Glass Tile

    private var memoryTile: some View {
        let visibleApps = Array((snapshot?.topMemoryApps ?? []).prefix(store.settings.maxMemoryApps))
        let pressure = snapshot?.memoryPressure ?? .normal
        let badgeColor = memoryBadgeColor(for: pressure)

        return GlassTile(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 10) {
                // Header row (tap to expand/collapse BOTH sub-metrics and app list)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.isMemoryExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        MetricSymbolBadge(
                            systemImage: "memorychip",
                            color: badgeColor,
                            size: 28,
                            iconSize: 13.5
                        )

                        Text("内存")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        MemoryPressureBadge(level: pressure)

                        Spacer(minLength: 4)

                        Text(memoryRatioText)
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.90))
                            .lineLimit(1)

                        Image(systemName: store.isMemoryExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(labelSecondaryColor)
                            .frame(width: 12, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 3-Column Mini Subtle Metric Pills (collapsible)
                if store.isMemoryExpanded {
                    HStack(spacing: 6) {
                        miniMetricCapsule(
                            title: "已压缩",
                            value: snapshot.map { MetricsFormatter.formatBytes($0.memoryCompressedBytes) } ?? "--"
                        )
                        miniMetricCapsule(
                            title: "缓存",
                            value: snapshot.map { MetricsFormatter.formatBytes($0.memoryCachedFilesBytes) } ?? "--"
                        )
                        miniMetricCapsule(
                            title: "交换",
                            value: snapshot.map { MetricsFormatter.formatBytes($0.swapUsedBytes) } ?? "--"
                        )
                    }
                    .transition(.opacity)
                }

                // Emerald 100% Memory Sparkline (always visible)
                AreaSparklineChart(
                    values: store.memoryHistory,
                    color: OrbitColors.memoryGreen(for: colorScheme),
                    ceiling: .fixed(maxValue: 100, label: "100%"),
                    height: 46
                )

                // Top Memory Apps List (collapsible together with sub-metrics!)
                if store.isMemoryExpanded, !visibleApps.isEmpty {
                    memoryAppsList(apps: visibleApps)
                        .transition(.opacity)
                }
            }
            .padding(13)
        }
    }

    private func memoryBadgeColor(for level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return OrbitColors.memoryGreen(for: colorScheme)
        case .warning: return OrbitColors.thermalWarm(for: colorScheme)
        case .critical: return OrbitColors.thermalHot(for: colorScheme)
        }
    }

    private var memoryRatioText: String {
        guard let snapshot else { return "-- / --" }
        let usedStr = MetricsFormatter.formatBytes(snapshot.memoryUsedBytes)
        let totalStr = MetricsFormatter.formatTotalMemory(snapshot.memoryTotalBytes)
        if usedStr.hasSuffix(" GB") && totalStr.hasSuffix(" GB") {
            let usedNum = usedStr.dropLast(3)
            return "\(usedNum) / \(totalStr)"
        }
        return "\(usedStr) / \(totalStr)"
    }

    private func miniMetricCapsule(title: String, value: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

        return VStack(alignment: .center, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(labelSecondaryColor)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.045))
        )
        .clipShape(shape)
    }

    private func memoryAppsList(apps: [AppMemoryUsage]) -> some View {
        let containerShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return VStack(spacing: 2) {
            ForEach(apps) { app in
                memoryAppRow(app: app)
            }
        }
        .padding(5)
        .background(
            containerShape.fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04))
        )
        .clipShape(containerShape)
    }

    private func memoryAppRow(app: AppMemoryUsage) -> some View {
        let isHovered = hoveredAppID == app.id

        return HStack(spacing: 8) {
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

            Text(MetricsFormatter.formatBytes(app.bytes))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.78 : 0.72))
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
            hoveredAppID = hovering ? app.id : (hoveredAppID == app.id ? nil : hoveredAppID)
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
                copyMemoryProcessInfo(app)
            }
        }
    }

    // MARK: - Actions

    private func openActivityMonitor() {
        let appURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
    }

    private func copyMemoryProcessInfo(_ app: AppMemoryUsage) {
        let sizeStr = MetricsFormatter.formatBytes(app.bytes)
        var lines = [
            "应用: \(app.name)",
            "PID: \(app.pid)",
            "内存占用: \(sizeStr)"
        ]
        if app.processCount > 1 {
            lines.append("关联进程数: \(app.processCount)")
        }
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
