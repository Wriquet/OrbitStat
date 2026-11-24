import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Native, rootless Power & Battery telemetry sampler for Apple Silicon macOS (14+).
///
/// Combines direct IOKit (`AppleSmartBattery`, `AppleSmartBatteryPack`, `IOPSCopyPowerSourcesInfo`),
/// direct `AppleSMC` sensor reads (`PSTR`, `PDTR`, `VD0R`, `ID0R`, `TB0T`/`TB1T`/`TB2T`), and
/// `libproc` (`proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_V4)`) process energy deltas.
/// Never shells out to external CLI tools (`ioreg`, `system_profiler`, `pmset`, etc.).
public actor PowerMonitor: PowerMonitorProtocol {
    // MARK: - Internal Sampling State

    private struct ProcessEnergySample {
        let cpuNanoseconds: Double
        let idleWakeups: UInt64
        let interruptWakeups: UInt64
        let startAbstime: UInt64
    }

    private struct RunningAppMetadata {
        let localizedName: String
        let bundleIdentifier: String?
        let pid: Int32
        let activationPolicy: NSApplication.ActivationPolicy
    }

    private struct BundleFallbackMetadata {
        let bundleIdentifier: String?
        let fallbackName: String
    }

    private let smcClient: SMCClient
    private let timebaseNumer: Double
    private let timebaseDenom: Double
    private let userApplicationsPrefix: String

    private var previousProcessSamples: [pid_t: ProcessEnergySample]
    private var previousSampleTimestamp: CFAbsoluteTime?
    private var bundleMetadataCache: [String: BundleFallbackMetadata] = [:]

    // MARK: - Initialization

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numer = timebase.numer > 0 ? Double(timebase.numer) : 1.0
        let denom = timebase.denom > 0 ? Double(timebase.denom) : 1.0
        self.timebaseNumer = numer
        self.timebaseDenom = denom
        self.smcClient = SMCClient()
        self.userApplicationsPrefix = NSHomeDirectory() + "/Applications/"

        // Seed an initial process-energy baseline (fast ~1-2 ms in-memory syscall pass)
        // so even an early sample after >= 50 ms yields accurate CPU/energy deltas.
        let now = CFAbsoluteTimeGetCurrent()
        self.previousProcessSamples = Self.captureProcessSamples(
            timebaseNumer: numer,
            timebaseDenom: denom
        )
        self.previousSampleTimestamp = now
    }

    // MARK: - PowerMonitorProtocol

    public func sample() async -> PowerSnapshot {
        let timestamp = Date()

        let batteryProps = Self.readIORegistryProperties(serviceClass: "AppleSmartBattery")
        let batteryPackProps = Self.readIORegistryProperties(serviceClass: "AppleSmartBatteryPack")
        let batteryData = batteryProps?["BatteryData"] as? [String: Any]
        let packBatteryData = batteryPackProps?["BatteryData"] as? [String: Any]
        let telemetryData = batteryProps?["PowerTelemetryData"] as? [String: Any]

        // Query IOPSCopyPowerSourcesInfo only as a lightweight fallback when AppleSmartBattery
        // is missing (e.g. Desktop Mac / edge hardware) or lacks key fields.
        let iopsBattery: [String: Any]? = (batteryProps == nil) ? Self.readIOPSInternalBattery() : nil

        let hasBattery = Self.detectHasBattery(
            batteryProps: batteryProps,
            iopsBattery: iopsBattery
        )

        let isPluggedIn: Bool
        if hasBattery {
            if let ext = Self.boolValue(batteryProps?["ExternalConnected"])
                ?? Self.boolValue(batteryProps?["AppleRawExternalConnected"]) {
                isPluggedIn = ext
            } else if let state = iopsBattery?[kIOPSPowerSourceStateKey as String] as? String {
                isPluggedIn = (state == (kIOPSACPowerValue as String))
            } else {
                isPluggedIn = false
            }
        } else {
            // Desktop Macs without an internal battery run on AC power.
            isPluggedIn = true
        }

        let isCharging: Bool
        let isFullyCharged: Bool
        let batteryPercent: Double
        let batteryTemperatureCelsius: Double?
        let batteryHealthPercent: Double?
        let cycleCount: Int?

        if hasBattery {
            isCharging = Self.boolValue(batteryProps?["IsCharging"])
                ?? Self.boolValue(iopsBattery?[kIOPSIsChargingKey as String])
                ?? false

            isFullyCharged = Self.boolValue(batteryProps?["FullyCharged"])
                ?? Self.boolValue(iopsBattery?[kIOPSIsChargedKey as String])
                ?? false

            let currentCap = Self.firstFiniteDouble([
                batteryProps?["CurrentCapacity"],
                batteryData?["CurrentCapacity"],
                iopsBattery?[kIOPSCurrentCapacityKey as String]
            ])
            let maxCap = Self.firstPositiveDouble([
                batteryProps?["MaxCapacity"],
                batteryData?["MaxCapacity"],
                iopsBattery?[kIOPSMaxCapacityKey as String]
            ])
            let rawCurrentCap = Self.firstFiniteDouble([
                batteryProps?["AppleRawCurrentCapacity"],
                batteryData?["AppleRawCurrentCapacity"],
                packBatteryData?["AppleRawCurrentCapacity"]
            ])
            let rawMaxCap = Self.firstPositiveDouble([
                batteryProps?["AppleRawMaxCapacity"],
                batteryData?["AppleRawMaxCapacity"],
                packBatteryData?["AppleRawMaxCapacity"],
                batteryData?["FullChargeCapacity"]
            ])

            batteryPercent = Self.computeBatteryPercent(
                currentCapacity: currentCap,
                maxCapacity: maxCap,
                rawCurrentCapacity: rawCurrentCap,
                rawMaxCapacity: rawMaxCap
            )

            // Battery temperature: AppleSmartBattery -> AppleSmartBatteryPack -> AppleSMC TB0T/TB1T/TB2T.
            let candidateRawTemps: [Any?] = [
                batteryProps?["Temperature"],
                batteryData?["Temperature"],
                batteryData?["VirtualTemperature"],
                packBatteryData?["Temperature"],
                packBatteryData?["VirtualTemperature"]
            ]
            batteryTemperatureCelsius = candidateRawTemps
                .compactMap { Self.parseBatteryTemperatureCelsius(rawTemperature: Self.doubleValue($0)) }
                .first ?? readSMCBatteryTemperatureCelsius()

            // Cycle count: AppleSmartBattery -> AppleSmartBatteryPack -> AppleSMC B0CT.
            let candidateCycles: [Int?] = [
                Self.intValue(batteryProps?["CycleCount"]),
                Self.intValue(packBatteryData?["CycleCount"]),
                Self.intValue(batteryData?["CycleCount"]),
                smcClient.readUInt16LE("B0CT").map(Int.init)
            ]
            cycleCount = candidateCycles.compactMap { $0 }.first(where: { $0 >= 0 })

            // Battery health % matching macOS System Settings Maximum Capacity %.
            let designCap = Self.firstPositiveDouble([
                batteryProps?["DesignCapacity"],
                batteryData?["DesignCapacity"],
                packBatteryData?["DesignCapacity"]
            ])
            let nominalCap = Self.firstPositiveDouble([
                batteryProps?["NominalChargeCapacity"],
                batteryData?["NominalChargeCapacity"],
                packBatteryData?["NominalChargeCapacity"]
            ])
            let packReserve = Self.firstPositiveDouble([
                packBatteryData?["PackReserve"],
                batteryData?["PackReserve"]
            ])

            batteryHealthPercent = Self.computeBatteryHealthPercent(
                designCapacity: designCap,
                nominalChargeCapacity: nominalCap,
                packReserve: packReserve,
                rawMaxCapacity: rawMaxCap,
                legacyMaxCapacity: maxCap
            )
        } else {
            isCharging = false
            isFullyCharged = false
            batteryPercent = 0.0
            batteryTemperatureCelsius = nil
            batteryHealthPercent = nil
            cycleCount = nil
        }

        // System total power (Watts) — live AppleSMC PSTR first, then IOKit PowerTelemetryData fallback.
        let smcPSTR = smcClient.readNumeric("PSTR")
        let telemetrySystemLoadMW = Self.doubleValue(telemetryData?["SystemLoad"])
        let telemetryEnergyConsumedMW = Self.doubleValue(telemetryData?["SystemEnergyConsumed"])
        let batteryVoltageMV = Self.doubleValue(batteryProps?["Voltage"])
            ?? Self.doubleValue(batteryProps?["AppleRawBatteryVoltage"])
            ?? Self.doubleValue(packBatteryData?["Voltage"])
        let batteryInstantAmperageMA = Self.signedInt64Value(batteryProps?["InstantAmperage"])
            ?? Self.signedInt64Value(batteryProps?["Amperage"])
            ?? Self.signedInt64Value(packBatteryData?["InstantAmperage"])
        let telemetryBatteryPowerMW = Self.signedInt64Value(telemetryData?["BatteryPower"])
            ?? Self.signedInt64Value(batteryData?["BatteryPower"])

        let systemPowerWatts = Self.computeSystemPowerWatts(
            smcPSTR: smcPSTR,
            telemetrySystemLoadMW: telemetrySystemLoadMW,
            telemetryEnergyConsumedMW: telemetryEnergyConsumedMW,
            batteryVoltageMV: batteryVoltageMV,
            batteryInstantAmperageMA: batteryInstantAmperageMA,
            telemetryBatteryPowerMW: telemetryBatteryPowerMW,
            isPluggedIn: isPluggedIn
        )

        // Power adapter rated max watts & live input watts (nil when unplugged or on desktop without adapter data).
        let adapterMaxWatts: Double?
        let adapterInputWatts: Double?

        if hasBattery && isPluggedIn {
            adapterMaxWatts = Self.extractAdapterMaxWatts(batteryProps: batteryProps)

            let smcPDTR = smcClient.readNumeric("PDTR")
            let smcVD0R = smcClient.readNumeric("VD0R")
            let smcID0R = smcClient.readNumeric("ID0R")
            let telemetryPowerInMW = Self.doubleValue(telemetryData?["SystemPowerIn"])
            let telemetryVoltageInMV = Self.doubleValue(telemetryData?["SystemVoltageIn"])
            let telemetryCurrentInMA = Self.doubleValue(telemetryData?["SystemCurrentIn"])

            adapterInputWatts = Self.computeAdapterInputWatts(
                isPluggedIn: isPluggedIn,
                smcPDTR: smcPDTR,
                smcVD0R: smcVD0R,
                smcID0R: smcID0R,
                telemetrySystemPowerInMW: telemetryPowerInMW,
                telemetryVoltageInMV: telemetryVoltageInMV,
                telemetryCurrentInMA: telemetryCurrentInMA,
                systemPowerWatts: systemPowerWatts,
                batteryPowerMW: telemetryBatteryPowerMW
            )
        } else {
            adapterMaxWatts = nil
            adapterInputWatts = nil
        }

        let significantEnergyApps = sampleSignificantEnergyApps()

        return PowerSnapshot(
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            isFullyCharged: isFullyCharged,
            hasBattery: hasBattery,
            batteryTemperatureCelsius: batteryTemperatureCelsius,
            systemPowerWatts: systemPowerWatts,
            adapterMaxWatts: adapterMaxWatts,
            adapterInputWatts: adapterInputWatts,
            batteryHealthPercent: batteryHealthPercent,
            cycleCount: cycleCount,
            significantEnergyApps: significantEnergyApps,
            timestamp: timestamp
        )
    }

    // MARK: - Pure Telemetry Computation Helpers (Internal for Unit Testing)

    internal static func computeBatteryPercent(
        currentCapacity: Double?,
        maxCapacity: Double?,
        rawCurrentCapacity: Double?,
        rawMaxCapacity: Double?
    ) -> Double {
        if let current = currentCapacity, let maxCap = maxCapacity,
           current.isFinite, maxCap.isFinite, maxCap > 0 {
            let pct = (current / maxCap) * 100.0
            return min(100.0, max(0.0, pct))
        }
        if let rawCurrent = rawCurrentCapacity, let rawMax = rawMaxCapacity,
           rawCurrent.isFinite, rawMax.isFinite, rawMax > 0 {
            let pct = (rawCurrent / rawMax) * 100.0
            return min(100.0, max(0.0, pct))
        }
        if let current = currentCapacity, current.isFinite, current >= 0, current <= 100 {
            return current
        }
        return 0.0
    }

    internal static func parseBatteryTemperatureCelsius(rawTemperature: Double?) -> Double? {
        guard let raw = rawTemperature, raw.isFinite, raw > 0 else { return nil }
        let celsius: Double
        if raw >= 500.0 && raw <= 6500.0 {
            // Apple Silicon AppleSmartBattery / AppleSmartBatteryPack Temperature is in centi-Celsius (e.g. 2819 -> 28.19 °C).
            celsius = raw / 100.0
        } else if raw >= 5.0 && raw <= 65.0 {
            celsius = raw
        } else {
            return nil
        }
        return (5.0 ... 65.0).contains(celsius) ? celsius : nil
    }

    internal static func computeBatteryHealthPercent(
        designCapacity: Double?,
        nominalChargeCapacity: Double?,
        packReserve: Double?,
        rawMaxCapacity: Double?,
        legacyMaxCapacity: Double?
    ) -> Double? {
        guard let design = designCapacity, design.isFinite, design > 0 else {
            return nil
        }

        let effectiveMax: Double?
        if let nominal = nominalChargeCapacity, nominal.isFinite, nominal > 0 {
            if let reserve = packReserve, reserve.isFinite, reserve > 0, reserve < design * 0.15 {
                // Apple gas gauges (e.g. bq40z651) subtract PackReserve from NominalChargeCapacity;
                // adding PackReserve back aligns with macOS System Settings Maximum Capacity %.
                effectiveMax = nominal + reserve
            } else {
                effectiveMax = nominal
            }
        } else if let rawMax = rawMaxCapacity, rawMax.isFinite, rawMax > 0 {
            effectiveMax = rawMax
        } else if let legacyMax = legacyMaxCapacity, legacyMax.isFinite, legacyMax > 200.0 {
            // Legacy Intel Macs exposed mAh in MaxCapacity; ignore normalized 100% values.
            effectiveMax = legacyMax
        } else {
            effectiveMax = nil
        }

        guard let maxValue = effectiveMax else { return nil }
        let health = (maxValue / design) * 100.0
        guard health.isFinite, health > 0 else { return nil }
        return min(100.0, max(0.0, health))
    }

    internal static func computeSystemPowerWatts(
        smcPSTR: Double?,
        telemetrySystemLoadMW: Double?,
        telemetryEnergyConsumedMW: Double?,
        batteryVoltageMV: Double?,
        batteryInstantAmperageMA: Int64?,
        telemetryBatteryPowerMW: Int64?,
        isPluggedIn: Bool
    ) -> Double? {
        // 1. Live real-time AppleSMC total system power (updates ~1 Hz on Apple Silicon).
        if let pstr = smcPSTR, pstr.isFinite, pstr > 0.05, pstr < 500.0 {
            return pstr
        }
        // 2. IOKit AppleSmartBattery PowerTelemetryData["SystemLoad"] (mW -> W).
        if let loadMW = telemetrySystemLoadMW, loadMW.isFinite {
            let watts = loadMW / 1000.0
            if watts > 0.05 && watts < 500.0 {
                return watts
            }
        }
        // 3. Battery discharge fallback when unplugged: |Voltage(mV) * InstantAmperage(mA)| / 1e6.
        if !isPluggedIn {
            if let vMV = batteryVoltageMV, let iMA = batteryInstantAmperageMA,
               vMV.isFinite, vMV > 0, iMA != 0 {
                let watts = abs(vMV * Double(iMA)) / 1_000_000.0
                if watts > 0.05 && watts < 500.0 {
                    return watts
                }
            }
            if let battMW = telemetryBatteryPowerMW, battMW != 0 {
                let watts = abs(Double(battMW)) / 1000.0
                if watts > 0.05 && watts < 500.0 {
                    return watts
                }
            }
        }
        // 4. PowerTelemetryData["SystemEnergyConsumed"] (mW -> W).
        if let consumedMW = telemetryEnergyConsumedMW, consumedMW.isFinite {
            let watts = consumedMW / 1000.0
            if watts > 0.05 && watts < 500.0 {
                return watts
            }
        }
        return nil
    }

    internal static func computeAdapterInputWatts(
        isPluggedIn: Bool,
        smcPDTR: Double?,
        smcVD0R: Double?,
        smcID0R: Double?,
        telemetrySystemPowerInMW: Double?,
        telemetryVoltageInMV: Double?,
        telemetryCurrentInMA: Double?,
        systemPowerWatts: Double?,
        batteryPowerMW: Int64?
    ) -> Double? {
        guard isPluggedIn else { return nil }

        // 1. Live AppleSMC DC-In power (PDTR, Watts).
        if let pdtr = smcPDTR, pdtr.isFinite, pdtr > 0.05, pdtr < 500.0 {
            return pdtr
        }
        // 2. Live AppleSMC DC-In Voltage * Current (VD0R * ID0R).
        if let v = smcVD0R, let i = smcID0R, v.isFinite, i.isFinite, v > 0, i > 0 {
            let watts = v * i
            if watts > 0.05 && watts < 500.0 {
                return watts
            }
        }
        // 3. IOKit PowerTelemetryData["SystemPowerIn"] (mW -> W).
        if let powerInMW = telemetrySystemPowerInMW, powerInMW.isFinite {
            let watts = powerInMW / 1000.0
            if watts > 0.05 && watts < 500.0 {
                return watts
            }
        }
        // 4. IOKit PowerTelemetryData["SystemVoltageIn"] * ["SystemCurrentIn"] (mV * mA -> W).
        if let vMV = telemetryVoltageInMV, let iMA = telemetryCurrentInMA,
           vMV.isFinite, iMA.isFinite, vMV > 0, iMA > 0 {
            let watts = (vMV * iMA) / 1_000_000.0
            if watts > 0.05 && watts < 500.0 {
                return watts
            }
        }
        // 5. Genuine 0 W adapter draw while plugged in (e.g. hold-charge / bypass mode).
        if let pdtr = smcPDTR, pdtr.isFinite, pdtr >= 0.0, pdtr <= 0.05 {
            return 0.0
        }
        if let powerInMW = telemetrySystemPowerInMW, powerInMW.isFinite, powerInMW == 0.0 {
            return 0.0
        }
        // 6. Final estimate when plugged in and sensors are unavailable: system load + positive charging power.
        if let sysW = systemPowerWatts, sysW.isFinite, sysW >= 0 {
            let battChargeW = max(0.0, Double(batteryPowerMW ?? 0) / 1000.0)
            let total = sysW + battChargeW
            if total >= 0 && total < 500.0 {
                return total
            }
        }
        return nil
    }

    internal static func outermostAppBundlePath(from executablePath: String) -> String? {
        guard executablePath.contains(".app") else { return nil }
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        var built = ""
        for (index, part) in components.enumerated() {
            if index == 0 && part.isEmpty { continue }
            built += "/"
            built += part
            if part.hasSuffix(".app") {
                return built
            }
        }
        return nil
    }

    internal static func computeEnergyImpact(
        cpuPercent: Double,
        idleWakeupsPerSec: Double,
        interruptWakeupsPerSec: Double
    ) -> Double {
        max(0.0, cpuPercent)
            + max(0.0, idleWakeupsPerSec) * 0.02
            + max(0.0, interruptWakeupsPerSec) * 0.01
    }

    // MARK: - Significant Energy Apps Sampling

    private func sampleSignificantEnergyApps() -> [EnergyAppUsage] {
        let now = CFAbsoluteTimeGetCurrent()
        let currentSamples = Self.captureProcessSamples(
            timebaseNumer: timebaseNumer,
            timebaseDenom: timebaseDenom
        )

        defer {
            previousProcessSamples = currentSamples
            previousSampleTimestamp = now
        }

        guard let prevTime = previousSampleTimestamp else {
            return []
        }

        let dt = now - prevTime
        // Avoid noisy division when two samples arrive nearly simultaneously.
        guard dt >= 0.05 else {
            return []
        }

        let runningAppsByPath = Self.snapshotRunningAppsByPath()
        var pathBuffer = [CChar](repeating: 0, count: 4096)

        struct AppAggregate {
            let bundlePath: String
            let name: String
            let bundleIdentifier: String?
            var representativePid: Int32
            var representativeCpu: Double
            var hasMainPid: Bool
            var totalCpuPercent: Double
            var totalEnergyImpact: Double
        }

        var grouped: [String: AppAggregate] = [:]

        for (pid, current) in currentSamples {
            guard let previous = previousProcessSamples[pid] else { continue }
            // Protect against PID reuse and counter resets.
            guard current.startAbstime == previous.startAbstime,
                  current.cpuNanoseconds >= previous.cpuNanoseconds else {
                continue
            }

            let deltaCpuNs = current.cpuNanoseconds - previous.cpuNanoseconds
            let cpuPercent = (deltaCpuNs / (dt * 1_000_000_000.0)) * 100.0
            let idleWkupsPerSec = current.idleWakeups >= previous.idleWakeups
                ? Double(current.idleWakeups - previous.idleWakeups) / dt
                : 0.0
            let intrWkupsPerSec = current.interruptWakeups >= previous.interruptWakeups
                ? Double(current.interruptWakeups - previous.interruptWakeups) / dt
                : 0.0

            // Skip idle processes before performing proc_pidpath syscalls.
            if cpuPercent < 0.05 && idleWkupsPerSec < 2.0 && intrWkupsPerSec < 4.0 {
                continue
            }

            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLen > 0 else { continue }
            let executablePath = String(cString: pathBuffer)

            guard let appPath = Self.outermostAppBundlePath(from: executablePath) else {
                continue
            }

            let runningMeta = runningAppsByPath[appPath]
            guard isUserFacingApp(appPath: appPath, runningMeta: runningMeta) else {
                continue
            }

            let impact = Self.computeEnergyImpact(
                cpuPercent: cpuPercent,
                idleWakeupsPerSec: idleWkupsPerSec,
                interruptWakeupsPerSec: intrWkupsPerSec
            )

            if var existing = grouped[appPath] {
                existing.totalCpuPercent += cpuPercent
                existing.totalEnergyImpact += impact
                if !existing.hasMainPid && cpuPercent > existing.representativeCpu {
                    existing.representativePid = pid
                    existing.representativeCpu = cpuPercent
                }
                grouped[appPath] = existing
            } else {
                let fallbackMeta = fallbackBundleMetadata(for: appPath)
                let displayName = runningMeta?.localizedName ?? fallbackMeta.fallbackName
                let bundleID = runningMeta?.bundleIdentifier ?? fallbackMeta.bundleIdentifier
                let mainPid = runningMeta?.pid ?? pid
                grouped[appPath] = AppAggregate(
                    bundlePath: appPath,
                    name: displayName,
                    bundleIdentifier: bundleID,
                    representativePid: mainPid,
                    representativeCpu: cpuPercent,
                    hasMainPid: runningMeta != nil,
                    totalCpuPercent: cpuPercent,
                    totalEnergyImpact: impact
                )
            }
        }

        // Filter to apps with measurable recent energy usage and sort descending.
        return grouped.values
            .filter { $0.totalEnergyImpact >= 0.3 || $0.totalCpuPercent >= 0.3 }
            .sorted { lhs, rhs in
                if lhs.totalEnergyImpact != rhs.totalEnergyImpact {
                    return lhs.totalEnergyImpact > rhs.totalEnergyImpact
                }
                if lhs.totalCpuPercent != rhs.totalCpuPercent {
                    return lhs.totalCpuPercent > rhs.totalCpuPercent
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(10)
            .map { agg in
                EnergyAppUsage(
                    id: agg.bundleIdentifier ?? agg.bundlePath,
                    name: agg.name,
                    bundleIdentifier: agg.bundleIdentifier,
                    bundlePath: agg.bundlePath,
                    pid: agg.representativePid,
                    cpuPercent: agg.totalCpuPercent,
                    energyImpact: agg.totalEnergyImpact
                )
            }
    }

    private func isUserFacingApp(appPath: String, runningMeta: RunningAppMetadata?) -> Bool {
        if let meta = runningMeta {
            if meta.activationPolicy == .regular {
                return true
            }
            if meta.activationPolicy == .prohibited {
                return false
            }
            // Keep accessory (menu-bar) user apps in standard Applications folders,
            // while filtering out system CoreServices/PrivateFrameworks agents.
            return appPath.hasPrefix("/Applications/")
                || appPath.hasPrefix("/System/Applications/")
                || appPath.hasPrefix(userApplicationsPrefix)
        }
        return appPath.hasPrefix("/Applications/")
            || appPath.hasPrefix("/System/Applications/")
            || appPath.hasPrefix(userApplicationsPrefix)
    }

    private func fallbackBundleMetadata(for appPath: String) -> BundleFallbackMetadata {
        if let cached = bundleMetadataCache[appPath] {
            return cached
        }
        let bundle = Bundle(path: appPath)
        let bundleID = bundle?.bundleIdentifier
        let rawName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        let cleanName = rawName.hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
        let meta = BundleFallbackMetadata(bundleIdentifier: bundleID, fallbackName: cleanName)
        if bundleMetadataCache.count > 256 {
            bundleMetadataCache.removeAll(keepingCapacity: true)
        }
        bundleMetadataCache[appPath] = meta
        return meta
    }

    private static func snapshotRunningAppsByPath() -> [String: RunningAppMetadata] {
        var map: [String: RunningAppMetadata] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleURL = app.bundleURL else { continue }
            let path = bundleURL.standardizedFileURL.path
            guard path.hasSuffix(".app") else { continue }

            let name: String
            if let loc = app.localizedName, !loc.isEmpty {
                name = loc
            } else {
                name = bundleURL.deletingPathExtension().lastPathComponent
            }

            let candidate = RunningAppMetadata(
                localizedName: name,
                bundleIdentifier: app.bundleIdentifier,
                pid: app.processIdentifier,
                activationPolicy: app.activationPolicy
            )

            if let existing = map[path] {
                // Prefer .regular (0) over .accessory (1) over .prohibited (2).
                if candidate.activationPolicy.rawValue < existing.activationPolicy.rawValue {
                    map[path] = candidate
                }
            } else {
                map[path] = candidate
            }
        }
        return map
    }

    private static func captureProcessSamples(
        timebaseNumer: Double,
        timebaseDenom: Double
    ) -> [pid_t: ProcessEnergySample] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [:] }

        // Note: proc_listallpids returns the NUMBER OF PIDs (not bytes).
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 128)
        let bufferBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let returnedCount = proc_listallpids(&pids, bufferBytes)
        guard returnedCount > 0 else { return [:] }

        let validCount = min(Int(returnedCount), pids.count)
        let tickToNs = timebaseNumer / timebaseDenom
        var result: [pid_t: ProcessEnergySample] = [:]
        result.reserveCapacity(validCount)

        for i in 0 ..< validCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rptr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rptr)
                }
            }
            guard rc == 0 else { continue }

            let cpuTicks = Double(info.ri_user_time) + Double(info.ri_system_time)
            result[pid] = ProcessEnergySample(
                cpuNanoseconds: cpuTicks * tickToNs,
                idleWakeups: info.ri_pkg_idle_wkups,
                interruptWakeups: info.ri_interrupt_wkups,
                startAbstime: info.ri_proc_start_abstime
            )
        }

        return result
    }

    // MARK: - IOKit & SMC Hardware Readers

    private func readSMCBatteryTemperatureCelsius() -> Double? {
        let keys = ["TB0T", "TB1T", "TB2T"]
        var validReadings: [Double] = []
        validReadings.reserveCapacity(keys.count)
        for key in keys {
            if let value = smcClient.readNumeric(key),
               value.isFinite,
               (5.0 ... 65.0).contains(value) {
                validReadings.append(value)
            }
        }
        guard !validReadings.isEmpty else { return nil }
        return validReadings.reduce(0.0, +) / Double(validReadings.count)
    }

    private static func detectHasBattery(
        batteryProps: [String: Any]?,
        iopsBattery: [String: Any]?
    ) -> Bool {
        if let props = batteryProps {
            if let installed = boolValue(props["BatteryInstalled"]) {
                return installed
            }
            if doubleValue(props["CurrentCapacity"]) != nil
                || doubleValue(props["MaxCapacity"]) != nil
                || (props["BatteryData"] as? [String: Any]) != nil {
                return true
            }
        }
        if let iops = iopsBattery {
            if let present = boolValue(iops[kIOPSIsPresentKey as String]) {
                return present
            }
            return true
        }
        return false
    }

    private static func extractAdapterMaxWatts(batteryProps: [String: Any]?) -> Double? {
        if let adapter = batteryProps?["AdapterDetails"] as? [String: Any],
           let watts = doubleValue(adapter["Watts"]), watts.isFinite, watts > 0 {
            return watts
        }
        if let rawAdapters = batteryProps?["AppleRawAdapterDetails"] as? [[String: Any]] {
            for adapter in rawAdapters {
                if let watts = doubleValue(adapter["Watts"]), watts.isFinite, watts > 0 {
                    return watts
                }
            }
        }
        if let iopsAdapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = doubleValue(iopsAdapter[kIOPSPowerAdapterWattsKey as String]),
           watts.isFinite, watts > 0 {
            return watts
        }
        return nil
    }

    private static func readIORegistryProperties(serviceClass: String) -> [String: Any]? {
        guard let matching = IOServiceMatching(serviceClass) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return props
    }

    private static func readIOPSInternalBattery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let type = desc[kIOPSTypeKey as String] as? String
            if type == (kIOPSInternalBatteryType as String) {
                return desc
            }
        }
        return nil
    }

    // MARK: - Safe CF/NSNumber Coercion Helpers

    private static func firstFiniteDouble(_ candidates: [Any?]) -> Double? {
        for candidate in candidates {
            if let value = doubleValue(candidate), value.isFinite {
                return value
            }
        }
        return nil
    }

    private static func firstPositiveDouble(_ candidates: [Any?]) -> Double? {
        for candidate in candidates {
            if let value = doubleValue(candidate), value.isFinite, value > 0 {
                return value
            }
        }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as UInt64:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(exactly: value)
        case let value as UInt64:
            return Int(exactly: value)
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    /// Safely decodes signed 64-bit IOKit values that may bridge as two's-complement `UInt64`
    /// (for example `InstantAmperage` or `BatteryPower` during battery discharge).
    internal static func signedInt64Value(_ raw: Any?) -> Int64? {
        switch raw {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as UInt64:
            return Int64(bitPattern: value)
        case let value as NSNumber:
            return value.int64Value
        default:
            return nil
        }
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool:
            return value
        case let value as Int:
            return value != 0
        case let value as NSNumber:
            return value.boolValue
        default:
            return nil
        }
    }
}

// MARK: - Persistent Low-Overhead AppleSMC Client

/// Direct unprivileged `AppleSMC` client using the exact 80-byte kernel `SMCKeyData_t` layout.
/// Owned exclusively by the `PowerMonitor` actor (serialized access, clean `IOServiceClose` in `deinit`).
private final class SMCClient {
    private struct SMCVers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
        var pad: UInt16 = 0
    }

    private struct SMCLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var pad0: UInt8 = 0
        var pad1: UInt8 = 0
        var pad2: UInt8 = 0
    }

    private typealias SMCBytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCVers()
        var pLimitData = SMCLimitData()
        var keyInfo = SMCKeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var pad: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes32 = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private static let kSMCSelector: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCGetKeyInfo: UInt8 = 9
    private static let typeFlt: UInt32 = fourCC("flt ")
    private static let typeSP78: UInt32 = fourCC("sp78")
    private static let typeFPE2: UInt32 = fourCC("fpe2")
    private static let typeUI16: UInt32 = fourCC("ui16")
    private static let typeUI8: UInt32 = fourCC("ui8 ")

    private let connection: io_connect_t
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    init() {
        assert(MemoryLayout<SMCKeyData>.stride == 80, "SMCKeyData must match 80-byte kernel struct")
        guard let matching = IOServiceMatching("AppleSMC") else {
            self.connection = IO_OBJECT_NULL
            return
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            self.connection = IO_OBJECT_NULL
            return
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = IO_OBJECT_NULL
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        self.connection = (kr == kIOReturnSuccess) ? conn : IO_OBJECT_NULL
    }

    deinit {
        if connection != IO_OBJECT_NULL {
            IOServiceClose(connection)
        }
    }

    func readNumeric(_ keyName: String) -> Double? {
        guard let (info, bytes) = readRaw(keyName) else { return nil }
        let size = Int(info.dataSize)
        guard bytes.count >= size else { return nil }

        switch info.dataType {
        case Self.typeFlt where size == 4:
            var value: Float32 = 0
            withUnsafeMutableBytes(of: &value) { dst in
                dst.copyBytes(from: bytes.prefix(4))
            }
            let d = Double(value)
            return d.isFinite ? d : nil

        case Self.typeSP78 where size == 2:
            let signed = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(signed) / 256.0

        case Self.typeFPE2 where size == 2:
            let unsigned = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(unsigned) / 4.0

        case Self.typeUI8 where size == 1:
            return Double(bytes[0])

        default:
            return nil
        }
    }

    func readUInt16LE(_ keyName: String) -> UInt16? {
        guard let (info, bytes) = readRaw(keyName),
              info.dataType == Self.typeUI16,
              info.dataSize == 2,
              bytes.count >= 2 else {
            return nil
        }
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    private func readRaw(_ keyName: String) -> (SMCKeyInfo, [UInt8])? {
        guard connection != IO_OBJECT_NULL else { return nil }
        let keyCode = Self.fourCC(keyName)

        let keyInfo: SMCKeyInfo
        if let cached = keyInfoCache[keyCode] {
            keyInfo = cached
        } else {
            var infoInput = SMCKeyData()
            var infoOutput = SMCKeyData()
            infoInput.key = keyCode
            infoInput.data8 = Self.kSMCGetKeyInfo
            var outSize = MemoryLayout<SMCKeyData>.stride
            let kr = IOConnectCallStructMethod(
                connection,
                Self.kSMCSelector,
                &infoInput,
                MemoryLayout<SMCKeyData>.stride,
                &infoOutput,
                &outSize
            )
            guard kr == kIOReturnSuccess, infoOutput.result == 0, infoOutput.keyInfo.dataSize <= 32 else {
                return nil
            }
            keyInfo = infoOutput.keyInfo
            keyInfoCache[keyCode] = keyInfo
        }

        var readInput = SMCKeyData()
        var readOutput = SMCKeyData()
        readInput.key = keyCode
        readInput.keyInfo.dataSize = keyInfo.dataSize
        readInput.data8 = Self.kSMCReadKey
        var outSize = MemoryLayout<SMCKeyData>.stride

        let kr = IOConnectCallStructMethod(
            connection,
            Self.kSMCSelector,
            &readInput,
            MemoryLayout<SMCKeyData>.stride,
            &readOutput,
            &outSize
        )
        guard kr == kIOReturnSuccess, readOutput.result == 0 else {
            return nil
        }

        let length = min(Int(keyInfo.dataSize), 32)
        let bytes = withUnsafeBytes(of: readOutput.bytes) { raw in
            Array(raw.prefix(length))
        }
        return (keyInfo, bytes)
    }

    private static func fourCC(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in s.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }
}
