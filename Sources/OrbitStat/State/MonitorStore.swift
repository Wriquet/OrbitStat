import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
public final class MonitorStore: ObservableObject {
    public static let maxHistoryCount = 60
    private static let settingsKey = "com.orbitstat.app.settings.v1"

    // MARK: - Published UI & Telemetry State

    @Published public var selectedTab: MetricTab = .system
    @Published public var isShowingSettings: Bool = false
    @Published public var isCPUExpanded: Bool = false
    @Published public var isMemoryExpanded: Bool = true

    @Published public private(set) var systemSnapshot: SystemSnapshot?
    @Published public private(set) var powerSnapshot: PowerSnapshot?

    /// 60-sample rolling histories:
    /// - cpuHistory: 0...100 (%)
    /// - memoryHistory: 0...100 (%)
    /// - batteryHistory: 0...100 (%)
    /// - systemPowerHistory: Watts (>= 0)
    @Published public private(set) var cpuHistory: [Double] = []
    @Published public private(set) var memoryHistory: [Double] = []
    @Published public private(set) var batteryHistory: [Double] = []
    @Published public private(set) var systemPowerHistory: [Double] = []

    @Published public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persistSettings(settings)
            if settings.launchAtLogin != oldValue.launchAtLogin {
                applyLaunchAtLogin(settings.launchAtLogin)
            }
            if settings.refreshIntervalSeconds != oldValue.refreshIntervalSeconds, isRunning {
                restartPollingLoop()
            }
        }
    }

    @Published public private(set) var launchAtLoginError: String?

    // MARK: - Private Dependencies & State

    private let systemMonitor: any SystemMonitorProtocol
    private let powerMonitor: any PowerMonitorProtocol
    private let userDefaults: UserDefaults
    private var pollingTask: Task<Void, Never>?
    private var isRunning = false
    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    // MARK: - Initialization

    public init(
        systemMonitor: any SystemMonitorProtocol = SystemMonitor(),
        powerMonitor: any PowerMonitorProtocol = PowerMonitor(),
        userDefaults: UserDefaults = .standard
    ) {
        self.systemMonitor = systemMonitor
        self.powerMonitor = powerMonitor
        self.userDefaults = userDefaults

        var loaded = Self.loadSettings(from: userDefaults)
        if Self.isRunningFromAppBundle {
            loaded.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
        self.settings = loaded
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - Polling Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        restartPollingLoop()
    }

    public func stop() {
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Performs a single asynchronous sample of both system and power telemetry off the MainActor.
    public func refreshNow() async {
        let sysMonitor = systemMonitor
        let pwrMonitor = powerMonitor
        let (sys, pwr) = await Self.fetchSnapshots(systemMonitor: sysMonitor, powerMonitor: pwrMonitor)
        apply(system: sys, power: pwr)
    }

    /// Runs `count` rapid samples separated by `delaySeconds` (useful for tests & CLI snapshot rendering).
    public func warmUpAndSample(count: Int = 3, delaySeconds: Double = 0.25) async {
        let iterations = max(1, count)
        for index in 0..<iterations {
            await refreshNow()
            if index + 1 < iterations {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
        }
    }

    /// Seeds snapshots and optional histories directly (useful for previews and deterministic tests).
    public func seed(
        system: SystemSnapshot?,
        power: PowerSnapshot?,
        cpuHistory: [Double]? = nil,
        memoryHistory: [Double]? = nil,
        batteryHistory: [Double]? = nil,
        systemPowerHistory: [Double]? = nil
    ) {
        self.systemSnapshot = system
        self.powerSnapshot = power
        if let cpuHistory { self.cpuHistory = Array(cpuHistory.suffix(Self.maxHistoryCount)) }
        if let memoryHistory { self.memoryHistory = Array(memoryHistory.suffix(Self.maxHistoryCount)) }
        if let batteryHistory { self.batteryHistory = Array(batteryHistory.suffix(Self.maxHistoryCount)) }
        if let systemPowerHistory { self.systemPowerHistory = Array(systemPowerHistory.suffix(Self.maxHistoryCount)) }
    }

    // MARK: - Menu Bar Summary

    /// Optional concise text displayed beside the native SF Symbol icon in the macOS menu bar.
    /// Returns `nil` when all menu-bar metric toggles are disabled.
    public var menuBarText: String? {
        var parts: [String] = []
        if settings.showMenuBarCPU {
            parts.append(MetricsFormatter.formatPercent(systemSnapshot?.cpuTotalUsage))
        }
        if settings.showMenuBarTemp {
            parts.append(MetricsFormatter.formatCompactTemperature(
                systemSnapshot?.cpuTemperatureCelsius,
                unit: settings.temperatureUnit
            ))
        }
        if settings.showMenuBarBattery, powerSnapshot?.hasBattery ?? true {
            parts.append(MetricsFormatter.formatPercent(powerSnapshot?.batteryPercent))
        }
        if settings.showMenuBarPower {
            if let watts = powerSnapshot?.systemPowerWatts {
                parts.append(MetricsFormatter.formatWatts(watts).replacingOccurrences(of: " ", with: ""))
            } else {
                parts.append("--W")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Low-Memory Cached App Icons

    /// Returns a crisp, small (18pt / 36px Retina) cached NSImage for the given application/process.
    public func appIcon(bundlePath: String?, bundleIdentifier: String?, pid: Int32) -> NSImage {
        let keyString: String
        if let bundlePath, !bundlePath.isEmpty {
            keyString = "path:\(bundlePath)"
        } else if let bundleIdentifier, !bundleIdentifier.isEmpty {
            keyString = "bid:\(bundleIdentifier)"
        } else {
            keyString = "pid:\(pid)"
        }

        let cacheKey = keyString as NSString
        if let cached = iconCache.object(forKey: cacheKey) {
            return cached
        }

        let rawIcon: NSImage
        if let bundlePath, !bundlePath.isEmpty, FileManager.default.fileExists(atPath: bundlePath) {
            rawIcon = NSWorkspace.shared.icon(forFile: bundlePath)
        } else if pid > 0, let running = NSRunningApplication(processIdentifier: pid), let icon = running.icon {
            rawIcon = icon
        } else if let bundleIdentifier,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            rawIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            rawIcon = NSWorkspace.shared.icon(for: .unixExecutable)
        }

        let smallIcon = Self.makeLightweightIcon(from: rawIcon, pointSize: 18)
        iconCache.setObject(smallIcon, forKey: cacheKey)
        return smallIcon
    }

    /// Convenience helper for `AppMemoryUsage`.
    public func icon(for app: AppMemoryUsage) -> NSImage {
        appIcon(bundlePath: app.bundlePath, bundleIdentifier: app.bundleIdentifier, pid: app.pid)
    }

    /// Convenience helper for `EnergyAppUsage`.
    public func icon(for app: EnergyAppUsage) -> NSImage {
        appIcon(bundlePath: app.bundlePath, bundleIdentifier: app.bundleIdentifier, pid: app.pid)
    }

    // MARK: - Internal Helpers

    private func restartPollingLoop() {
        pollingTask?.cancel()
        let interval = min(60.0, max(0.5, settings.refreshIntervalSeconds))
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshNow()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
            }
        }
    }

    private nonisolated static func fetchSnapshots(
        systemMonitor: any SystemMonitorProtocol,
        powerMonitor: any PowerMonitorProtocol
    ) async -> (SystemSnapshot, PowerSnapshot) {
        async let sys = systemMonitor.sample()
        async let pwr = powerMonitor.sample()
        return await (sys, pwr)
    }

    private func apply(system: SystemSnapshot, power: PowerSnapshot) {
        systemSnapshot = system
        powerSnapshot = power

        appendHistory(&cpuHistory, value: min(100.0, max(0.0, system.cpuTotalUsage)))
        appendHistory(&memoryHistory, value: system.memoryUsagePercent)
        if power.hasBattery {
            appendHistory(&batteryHistory, value: min(100.0, max(0.0, power.batteryPercent)))
        }
        if let watts = power.systemPowerWatts, watts.isFinite {
            appendHistory(&systemPowerHistory, value: max(0.0, watts))
        }
    }

    private func appendHistory(_ array: inout [Double], value: Double) {
        array.append(value)
        if array.count > Self.maxHistoryCount {
            array.removeFirst(array.count - Self.maxHistoryCount)
        }
    }

    private func persistSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: Self.settingsKey)
    }

    private static func loadSettings(from userDefaults: UserDefaults) -> AppSettings {
        guard let data = userDefaults.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        guard Self.isRunningFromAppBundle else {
            launchAtLoginError = "仅在打包为 .app 应用后支持开机自动启动"
            return
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }

    private static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Downscales multi-resolution NSWorkspace icons to a lightweight 2x bitmap (36x36 px)
    /// to avoid retaining multi-megabyte 1024x1024 icon representations in memory.
    private static func makeLightweightIcon(from source: NSImage, pointSize: CGFloat) -> NSImage {
        let pixelSize = Int(pointSize * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            let copy = NSImage(size: NSSize(width: pointSize, height: pointSize))
            copy.lockFocus()
            source.draw(in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
            copy.unlockFocus()
            return copy
        }
        rep.size = NSSize(width: pointSize, height: pointSize)

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            source.draw(
                in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: NSSize(width: pointSize, height: pointSize))
        result.addRepresentation(rep)
        return result
    }
}
