import Foundation

// MARK: - Core Enums

public enum MetricTab: String, CaseIterable, Identifiable, Sendable {
    case system
    case power

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "系统"
        case .power: return "电源"
        }
    }

    public var systemImage: String {
        switch self {
        case .system: return "cpu"
        case .power: return "bolt.fill"
        }
    }
}

public enum TemperatureUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }
}

public enum MemoryPressureLevel: String, Codable, Sendable {
    case normal
    case warning
    case critical

    public var displayTitle: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "注意"
        case .critical: return "严重"
        }
    }
}

// MARK: - System Telemetry Models

/// Per-core CPU usage reading.
/// `usage` is a percentage in `0.0 ... 100.0`.
public struct CoreUsage: Identifiable, Equatable, Sendable {
    public let id: Int
    public let usage: Double
    public let isPerformanceCore: Bool?

    public init(id: Int, usage: Double, isPerformanceCore: Bool? = nil) {
        self.id = id
        self.usage = usage
        self.isPerformanceCore = isPerformanceCore
    }
}

/// Aggregated physical memory usage for an application or standalone process.
public struct AppMemoryUsage: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let pid: Int32
    public let bytes: UInt64
    public let processCount: Int

    public init(
        id: String,
        name: String,
        bundleIdentifier: String?,
        bundlePath: String?,
        pid: Int32,
        bytes: UInt64,
        processCount: Int
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.pid = pid
        self.bytes = bytes
        self.processCount = processCount
    }
}

/// Point-in-time snapshot of CPU, memory, and uptime metrics.
/// CPU usage fields are percentages in `0.0 ... 100.0`.
/// `memoryPressureRatio` is normalized in `0.0 ... 1.0`.
public struct SystemSnapshot: Equatable, Sendable {
    public let cpuTemperatureCelsius: Double?
    public let cpuTotalUsage: Double
    public let cpuUserUsage: Double
    public let cpuSystemUsage: Double
    public let cpuIdleUsage: Double
    public let perCoreUsage: [CoreUsage]
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let memoryCompressedBytes: UInt64
    public let memoryCachedFilesBytes: UInt64
    public let swapUsedBytes: UInt64
    public let memoryPressure: MemoryPressureLevel
    public let memoryPressureRatio: Double
    public let topMemoryApps: [AppMemoryUsage]
    public let uptimeSeconds: TimeInterval
    public let timestamp: Date

    public init(
        cpuTemperatureCelsius: Double?,
        cpuTotalUsage: Double,
        cpuUserUsage: Double,
        cpuSystemUsage: Double,
        cpuIdleUsage: Double,
        perCoreUsage: [CoreUsage],
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        memoryCompressedBytes: UInt64,
        memoryCachedFilesBytes: UInt64,
        swapUsedBytes: UInt64,
        memoryPressure: MemoryPressureLevel,
        memoryPressureRatio: Double,
        topMemoryApps: [AppMemoryUsage],
        uptimeSeconds: TimeInterval,
        timestamp: Date = Date()
    ) {
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.cpuTotalUsage = cpuTotalUsage
        self.cpuUserUsage = cpuUserUsage
        self.cpuSystemUsage = cpuSystemUsage
        self.cpuIdleUsage = cpuIdleUsage
        self.perCoreUsage = perCoreUsage
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryCompressedBytes = memoryCompressedBytes
        self.memoryCachedFilesBytes = memoryCachedFilesBytes
        self.swapUsedBytes = swapUsedBytes
        self.memoryPressure = memoryPressure
        self.memoryPressureRatio = memoryPressureRatio
        self.topMemoryApps = topMemoryApps
        self.uptimeSeconds = uptimeSeconds
        self.timestamp = timestamp
    }

    /// Memory usage as a percentage in `0.0 ... 100.0`.
    public var memoryUsagePercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(100.0, max(0.0, (Double(memoryUsedBytes) / Double(memoryTotalBytes)) * 100.0))
    }
}

// MARK: - Power Telemetry Models

/// Application contributing significant recent energy / CPU impact.
public struct EnergyAppUsage: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let pid: Int32
    public let cpuPercent: Double
    public let energyImpact: Double

    public init(
        id: String,
        name: String,
        bundleIdentifier: String?,
        bundlePath: String?,
        pid: Int32,
        cpuPercent: Double,
        energyImpact: Double
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.energyImpact = energyImpact
    }
}

/// Point-in-time snapshot of battery, thermal, system power, and adapter metrics.
/// `batteryPercent` and `batteryHealthPercent` are percentages in `0.0 ... 100.0`.
public struct PowerSnapshot: Equatable, Sendable {
    public let batteryPercent: Double
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let isFullyCharged: Bool
    public let hasBattery: Bool
    public let batteryTemperatureCelsius: Double?
    public let systemPowerWatts: Double?
    public let adapterMaxWatts: Double?
    public let adapterInputWatts: Double?
    public let batteryHealthPercent: Double?
    public let cycleCount: Int?
    public let significantEnergyApps: [EnergyAppUsage]
    public let timestamp: Date

    public init(
        batteryPercent: Double,
        isCharging: Bool,
        isPluggedIn: Bool,
        isFullyCharged: Bool,
        hasBattery: Bool,
        batteryTemperatureCelsius: Double?,
        systemPowerWatts: Double?,
        adapterMaxWatts: Double?,
        adapterInputWatts: Double?,
        batteryHealthPercent: Double?,
        cycleCount: Int?,
        significantEnergyApps: [EnergyAppUsage],
        timestamp: Date = Date()
    ) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isFullyCharged = isFullyCharged
        self.hasBattery = hasBattery
        self.batteryTemperatureCelsius = batteryTemperatureCelsius
        self.systemPowerWatts = systemPowerWatts
        self.adapterMaxWatts = adapterMaxWatts
        self.adapterInputWatts = adapterInputWatts
        self.batteryHealthPercent = batteryHealthPercent
        self.cycleCount = cycleCount
        self.significantEnergyApps = significantEnergyApps
        self.timestamp = timestamp
    }
}

// MARK: - Monitor Service Protocols

public protocol SystemMonitorProtocol: Sendable {
    func sample() async -> SystemSnapshot
}

public protocol PowerMonitorProtocol: Sendable {
    func sample() async -> PowerSnapshot
}

// MARK: - Settings

public struct AppSettings: Codable, Equatable, Sendable {
    public var refreshIntervalSeconds: Double
    public var temperatureUnit: TemperatureUnit
    public var maxMemoryApps: Int
    public var showMenuBarCPU: Bool
    public var showMenuBarTemp: Bool
    public var showMenuBarBattery: Bool
    public var showMenuBarPower: Bool
    public var launchAtLogin: Bool
    public var showSystemTempCard: Bool
    public var showSystemCPUCard: Bool
    public var showSystemMemoryCard: Bool
    public var showPowerBatteryCard: Bool
    public var showPowerTempRow: Bool
    public var showPowerSystemCard: Bool
    public var showPowerAdapterRow: Bool
    public var showPowerHealthRow: Bool

    public init(
        refreshIntervalSeconds: Double = 2.0,
        temperatureUnit: TemperatureUnit = .celsius,
        maxMemoryApps: Int = 15,
        showMenuBarCPU: Bool = false,
        showMenuBarTemp: Bool = false,
        showMenuBarBattery: Bool = false,
        showMenuBarPower: Bool = false,
        launchAtLogin: Bool = false,
        showSystemTempCard: Bool = true,
        showSystemCPUCard: Bool = true,
        showSystemMemoryCard: Bool = true,
        showPowerBatteryCard: Bool = true,
        showPowerTempRow: Bool = true,
        showPowerSystemCard: Bool = true,
        showPowerAdapterRow: Bool = true,
        showPowerHealthRow: Bool = true
    ) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.temperatureUnit = temperatureUnit
        self.maxMemoryApps = maxMemoryApps
        self.showMenuBarCPU = showMenuBarCPU
        self.showMenuBarTemp = showMenuBarTemp
        self.showMenuBarBattery = showMenuBarBattery
        self.showMenuBarPower = showMenuBarPower
        self.launchAtLogin = launchAtLogin
        self.showSystemTempCard = showSystemTempCard
        self.showSystemCPUCard = showSystemCPUCard
        self.showSystemMemoryCard = showSystemMemoryCard
        self.showPowerBatteryCard = showPowerBatteryCard
        self.showPowerTempRow = showPowerTempRow
        self.showPowerSystemCard = showPowerSystemCard
        self.showPowerAdapterRow = showPowerAdapterRow
        self.showPowerHealthRow = showPowerHealthRow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.refreshIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? 2.0
        self.temperatureUnit = try c.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit) ?? .celsius
        self.maxMemoryApps = try c.decodeIfPresent(Int.self, forKey: .maxMemoryApps) ?? 15
        self.showMenuBarCPU = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarCPU) ?? false
        self.showMenuBarTemp = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarTemp) ?? false
        self.showMenuBarBattery = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarBattery) ?? false
        self.showMenuBarPower = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarPower) ?? false
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.showSystemTempCard = try c.decodeIfPresent(Bool.self, forKey: .showSystemTempCard) ?? true
        self.showSystemCPUCard = try c.decodeIfPresent(Bool.self, forKey: .showSystemCPUCard) ?? true
        self.showSystemMemoryCard = try c.decodeIfPresent(Bool.self, forKey: .showSystemMemoryCard) ?? true
        self.showPowerBatteryCard = try c.decodeIfPresent(Bool.self, forKey: .showPowerBatteryCard) ?? true
        self.showPowerTempRow = try c.decodeIfPresent(Bool.self, forKey: .showPowerTempRow) ?? true
        self.showPowerSystemCard = try c.decodeIfPresent(Bool.self, forKey: .showPowerSystemCard) ?? true
        self.showPowerAdapterRow = try c.decodeIfPresent(Bool.self, forKey: .showPowerAdapterRow) ?? true
        self.showPowerHealthRow = try c.decodeIfPresent(Bool.self, forKey: .showPowerHealthRow) ?? true
    }
}

// MARK: - Formatting Helpers

public enum MetricsFormatter {
    private static let kib: Double = 1024.0
    private static let mib: Double = 1024.0 * 1024.0
    private static let gib: Double = 1024.0 * 1024.0 * 1024.0
    private static let tib: Double = 1024.0 * 1024.0 * 1024.0 * 1024.0

    /// Formats byte counts matching macOS Activity Monitor / Vorssaint style:
    /// e.g. "16 GB", "4.68 GB", "887.9 MB", "199 MB", "512 KB".
    public static func formatBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= tib {
            let tb = value / tib
            return "\(formatNumber(tb, maxDecimals: 2, keepFixedWhenNonInteger: true)) TB"
        } else if value >= gib {
            let gb = value / gib
            return "\(formatNumber(gb, maxDecimals: 2, keepFixedWhenNonInteger: true)) GB"
        } else if value >= mib {
            let mb = value / mib
            return "\(formatNumber(mb, maxDecimals: 1, keepFixedWhenNonInteger: false)) MB"
        } else if value >= kib {
            let kb = value / kib
            return "\(Int(round(kb))) KB"
        } else {
            return "\(bytes) B"
        }
    }

    /// Formats total system memory cleanly (e.g. "16 GB", "24 GB", "32 GB").
    public static func formatTotalMemory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / gib
        let rounded = round(gb)
        if abs(gb - rounded) < 0.05, rounded >= 1 {
            return "\(Int(rounded)) GB"
        }
        return formatBytes(bytes)
    }

    /// Formats temperature in the requested unit (e.g. "37 °C", "99 °F", or "--").
    public static func formatTemperature(_ celsius: Double?, unit: TemperatureUnit = .celsius) -> String {
        guard let celsius, celsius.isFinite else { return "--" }
        switch unit {
        case .celsius:
            return "\(Int(round(celsius))) °C"
        case .fahrenheit:
            let f = celsius * 9.0 / 5.0 + 32.0
            return "\(Int(round(f))) °F"
        }
    }

    /// Compact temperature for menu bar (e.g. "37°C").
    public static func formatCompactTemperature(_ celsius: Double?, unit: TemperatureUnit = .celsius) -> String {
        guard let celsius, celsius.isFinite else { return "--" }
        switch unit {
        case .celsius:
            return "\(Int(round(celsius)))°C"
        case .fahrenheit:
            let f = celsius * 9.0 / 5.0 + 32.0
            return "\(Int(round(f)))°F"
        }
    }

    /// Formats power in watts matching Vorssaint style:
    /// - Values >= 10 W with `preferIntegerAboveTen = true`: integer (e.g. "10 W", "60 W")
    /// - Values < 10 W (or `preferIntegerAboveTen = false`): up to 1 decimal (e.g. "7.8 W", "8 W")
    public static func formatWatts(_ watts: Double?, preferIntegerAboveTen: Bool = true) -> String {
        guard let watts, watts.isFinite else { return "--" }
        let clamped = max(0, watts)
        if preferIntegerAboveTen && clamped >= 9.95 {
            return "\(Int(round(clamped))) W"
        }
        let roundedOneDecimal = (clamped * 10.0).rounded() / 10.0
        if abs(roundedOneDecimal - roundedOneDecimal.rounded()) < 0.001 {
            return "\(Int(roundedOneDecimal.rounded())) W"
        }
        return String(format: "%.1f W", roundedOneDecimal)
    }

    /// Formats adapter rated maximum wattage (e.g. "60 W", "140 W").
    public static func formatWholeWatts(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else { return "--" }
        return "\(Int(round(max(0, watts)))) W"
    }

    /// Formats percentage as rounded integer (e.g. "10%", "80%", "96%").
    public static func formatPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        let clamped = min(100.0, max(0.0, value))
        return "\(Int(round(clamped)))%"
    }

    /// Formats percentage with 1 decimal for detailed breakdowns (e.g. "6.4%").
    public static func formatDetailedPercent(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        return String(format: "%.1f%%", max(0.0, value))
    }

    /// Formats system uptime (e.g. "3d 0h", "5h 24m", "18m").
    public static func formatUptime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0m" }
        let totalMinutes = Int(seconds) / 60
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private static func formatNumber(_ value: Double, maxDecimals: Int, keepFixedWhenNonInteger: Bool) -> String {
        let factor = pow(10.0, Double(maxDecimals))
        let rounded = (value * factor).rounded() / factor
        if abs(rounded - rounded.rounded()) < 1e-6 {
            return "\(Int(rounded.rounded()))"
        }
        if keepFixedWhenNonInteger {
            return String(format: "%.\(maxDecimals)f", rounded)
        }
        // Trim trailing zero for single-decimal MB formatting (e.g. 199.0 -> 199, 887.9 -> 887.9)
        let formatted = String(format: "%.\(maxDecimals)f", rounded)
        if formatted.hasSuffix(".0") {
            return String(formatted.dropLast(2))
        }
        return formatted
    }
}
