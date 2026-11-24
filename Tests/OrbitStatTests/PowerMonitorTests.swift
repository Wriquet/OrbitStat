import Foundation
import Testing
@testable import OrbitStat

@Suite("PowerMonitor Telemetry & Calculations")
struct PowerMonitorTests {

    // MARK: - Live Hardware Integration Test

    @Test("Live PowerMonitor snapshot returns real non-root telemetry")
    func livePowerSnapshotTelemetry() async throws {
        let monitor = PowerMonitor()

        // Allow a short interval so process rusage deltas accumulate naturally.
        try await Task.sleep(for: .milliseconds(350))
        let first = await monitor.sample()

        try await Task.sleep(for: .milliseconds(350))
        let snapshot = await monitor.sample()

        #expect(snapshot.timestamp >= first.timestamp)

        // System total power should be real, positive, and plausible on Apple Silicon without root.
        let systemWatts = try #require(
            snapshot.systemPowerWatts,
            "Expected real non-nil systemPowerWatts from AppleSMC PSTR or IOKit PowerTelemetryData"
        )
        #expect(systemWatts > 0.1)
        #expect(systemWatts < 500.0)

        if snapshot.hasBattery {
            #expect(snapshot.batteryPercent >= 0.0)
            #expect(snapshot.batteryPercent <= 100.0)

            let tempC = try #require(
                snapshot.batteryTemperatureCelsius,
                "Expected real batteryTemperatureCelsius on battery-equipped Mac"
            )
            #expect(tempC >= 5.0)
            #expect(tempC <= 65.0)

            let health = try #require(
                snapshot.batteryHealthPercent,
                "Expected real batteryHealthPercent on battery-equipped Mac"
            )
            #expect(health >= 10.0)
            #expect(health <= 100.0)

            let cycles = try #require(
                snapshot.cycleCount,
                "Expected real cycleCount on battery-equipped Mac"
            )
            #expect(cycles >= 0)
            #expect(cycles < 5000)

            if snapshot.isPluggedIn {
                if let maxW = snapshot.adapterMaxWatts {
                    #expect(maxW > 0.0)
                    #expect(maxW < 500.0)
                }
                let inputW = try #require(
                    snapshot.adapterInputWatts,
                    "Expected adapterInputWatts when external power is connected"
                )
                #expect(inputW >= 0.0)
                #expect(inputW < 500.0)
            } else {
                #expect(!snapshot.isCharging)
                #expect(snapshot.adapterMaxWatts == nil)
                #expect(snapshot.adapterInputWatts == nil)
            }
        } else {
            // Desktop Mac graceful handling
            #expect(snapshot.batteryPercent == 0.0)
            #expect(!snapshot.isCharging)
            #expect(!snapshot.isFullyCharged)
            #expect(snapshot.batteryTemperatureCelsius == nil)
            #expect(snapshot.batteryHealthPercent == nil)
            #expect(snapshot.cycleCount == nil)
            #expect(snapshot.adapterMaxWatts == nil)
            #expect(snapshot.adapterInputWatts == nil)
        }

        // Validate significant energy apps invariants (sorting, deduplication, fields).
        var seenIDs = Set<String>()
        var previousImpact = Double.infinity
        for app in snapshot.significantEnergyApps {
            #expect(!app.id.isEmpty)
            #expect(!app.name.isEmpty)
            #expect(seenIDs.insert(app.id).inserted)
            #expect(app.pid > 0)
            #expect(app.cpuPercent >= 0.0)
            #expect(app.energyImpact >= 0.0)
            #expect(app.energyImpact <= previousImpact + 1e-9)
            if let path = app.bundlePath {
                #expect(path.hasSuffix(".app"))
            }
            previousImpact = app.energyImpact
        }

        let topAppsSummary = snapshot.significantEnergyApps.prefix(5)
            .map { "\($0.name)(\(String(format: "%.1f%%", $0.cpuPercent)))" }
            .joined(separator: ", ")
        print(
            """
            [PowerMonitorTests Live] hasBattery=\(snapshot.hasBattery) \
            battery=\(String(format: "%.1f%%", snapshot.batteryPercent)) \
            pluggedIn=\(snapshot.isPluggedIn) charging=\(snapshot.isCharging) \
            temp=\(snapshot.batteryTemperatureCelsius.map { String(format: "%.2f°C", $0) } ?? "nil") \
            sysW=\(String(format: "%.2fW", systemWatts)) \
            adapterMax=\(snapshot.adapterMaxWatts.map { String(format: "%.0fW", $0) } ?? "nil") \
            adapterIn=\(snapshot.adapterInputWatts.map { String(format: "%.2fW", $0) } ?? "nil") \
            health=\(snapshot.batteryHealthPercent.map { String(format: "%.2f%%", $0) } ?? "nil") \
            cycles=\(snapshot.cycleCount.map(String.init) ?? "nil") \
            energyApps=[\(topAppsSummary)]
            """
        )
    }

    // MARK: - Deterministic Unit Tests

    @Test("Battery percentage computation handles normalized, raw, clamped, and missing inputs")
    func batteryPercentCalculation() {
        let normal = PowerMonitor.computeBatteryPercent(
            currentCapacity: 80,
            maxCapacity: 100,
            rawCurrentCapacity: 3313,
            rawMaxCapacity: 4193
        )
        #expect(abs(normal - 80.0) < 0.001)

        let rawFallback = PowerMonitor.computeBatteryPercent(
            currentCapacity: nil,
            maxCapacity: nil,
            rawCurrentCapacity: 3313,
            rawMaxCapacity: 4193
        )
        #expect(abs(rawFallback - (3313.0 / 4193.0) * 100.0) < 0.001)

        let clamped = PowerMonitor.computeBatteryPercent(
            currentCapacity: 112,
            maxCapacity: 100,
            rawCurrentCapacity: nil,
            rawMaxCapacity: nil
        )
        #expect(abs(clamped - 100.0) < 0.001)

        let missing = PowerMonitor.computeBatteryPercent(
            currentCapacity: nil,
            maxCapacity: nil,
            rawCurrentCapacity: nil,
            rawMaxCapacity: nil
        )
        #expect(missing == 0.0)
    }

    @Test("Battery temperature parser decodes centi-Celsius and validates 5..65 °C range")
    func batteryTemperatureParsing() throws {
        let centi = try #require(PowerMonitor.parseBatteryTemperatureCelsius(rawTemperature: 2819))
        #expect(abs(centi - 28.19) < 0.001)

        let direct = try #require(PowerMonitor.parseBatteryTemperatureCelsius(rawTemperature: 28.4))
        #expect(abs(direct - 28.4) < 0.001)

        #expect(PowerMonitor.parseBatteryTemperatureCelsius(rawTemperature: nil) == nil)
        #expect(PowerMonitor.parseBatteryTemperatureCelsius(rawTemperature: 0) == nil)
        #expect(PowerMonitor.parseBatteryTemperatureCelsius(rawTemperature: -500) == nil)
        #expect(PowerMonitor.parseBatteryTemperatureCelsius(rawTemperature: 99999) == nil)
        #expect(PowerMonitor.parseBatteryTemperatureCelsius(rawTemperature: .nan) == nil)
    }

    @Test("Battery health calculation aligns with macOS System Settings Maximum Capacity %")
    func batteryHealthCalculation() throws {
        // Matches live Apple Silicon Mac17,3: (4319 + 127) / 4629 = 96.05% -> "96%"
        let withReserve = try #require(
            PowerMonitor.computeBatteryHealthPercent(
                designCapacity: 4629,
                nominalChargeCapacity: 4319,
                packReserve: 127,
                rawMaxCapacity: 4192,
                legacyMaxCapacity: 100
            )
        )
        #expect(abs(withReserve - 96.0466) < 0.01)
        #expect(MetricsFormatter.formatPercent(withReserve) == "96%")

        // Without PackReserve -> NominalChargeCapacity / DesignCapacity
        let withoutReserve = try #require(
            PowerMonitor.computeBatteryHealthPercent(
                designCapacity: 4629,
                nominalChargeCapacity: 4319,
                packReserve: nil,
                rawMaxCapacity: 4192,
                legacyMaxCapacity: 100
            )
        )
        #expect(abs(withoutReserve - 93.303) < 0.01)

        // Fallback to AppleRawMaxCapacity when NominalChargeCapacity missing
        let rawFallback = try #require(
            PowerMonitor.computeBatteryHealthPercent(
                designCapacity: 4629,
                nominalChargeCapacity: nil,
                packReserve: nil,
                rawMaxCapacity: 4192,
                legacyMaxCapacity: 100
            )
        )
        #expect(abs(rawFallback - 90.559) < 0.01)

        // Normalized MaxCapacity=100 must NOT be divided by DesignCapacity=4629
        #expect(
            PowerMonitor.computeBatteryHealthPercent(
                designCapacity: 4629,
                nominalChargeCapacity: nil,
                packReserve: nil,
                rawMaxCapacity: nil,
                legacyMaxCapacity: 100
            ) == nil
        )

        // Fresh cells exceeding rated design capacity clamp to 100%
        let freshHealth = try #require(
            PowerMonitor.computeBatteryHealthPercent(
                designCapacity: 4629,
                nominalChargeCapacity: 4700,
                packReserve: 120,
                rawMaxCapacity: 4680,
                legacyMaxCapacity: 100
            )
        )
        #expect(abs(freshHealth - 100.0) < 0.001)
    }

    @Test("System power prioritizes live SMC PSTR with IOKit and signed discharge fallbacks")
    func systemPowerWattsPriorityAndDischargeFallback() throws {
        // 1. Live SMC PSTR preferred
        let smc = try #require(
            PowerMonitor.computeSystemPowerWatts(
                smcPSTR: 10.2,
                telemetrySystemLoadMW: 9757,
                telemetryEnergyConsumedMW: 9479,
                batteryVoltageMV: 12839,
                batteryInstantAmperageMA: 1898,
                telemetryBatteryPowerMW: 24368,
                isPluggedIn: true
            )
        )
        #expect(abs(smc - 10.2) < 0.001)

        // 2. Fallback to PowerTelemetryData["SystemLoad"] (mW -> W)
        let load = try #require(
            PowerMonitor.computeSystemPowerWatts(
                smcPSTR: nil,
                telemetrySystemLoadMW: 9757,
                telemetryEnergyConsumedMW: 9479,
                batteryVoltageMV: 12839,
                batteryInstantAmperageMA: 1898,
                telemetryBatteryPowerMW: 24368,
                isPluggedIn: true
            )
        )
        #expect(abs(load - 9.757) < 0.001)

        // 3. Fallback to signed battery discharge Voltage * InstantAmperage when unplugged
        let signedAmperage = PowerMonitor.signedInt64Value(UInt64(18446744073709550959))
        #expect(signedAmperage == -657)
        let discharge = try #require(
            PowerMonitor.computeSystemPowerWatts(
                smcPSTR: nil,
                telemetrySystemLoadMW: nil,
                telemetryEnergyConsumedMW: nil,
                batteryVoltageMV: 12431,
                batteryInstantAmperageMA: signedAmperage,
                telemetryBatteryPowerMW: -8167,
                isPluggedIn: false
            )
        )
        #expect(abs(discharge - 8.167) < 0.001)
    }

    @Test("Adapter input watts handles unplugged nil, live SMC PDTR, and IOKit SystemPowerIn")
    func adapterInputWattsPluggedAndUnplugged() throws {
        // Unplugged must always return nil
        #expect(
            PowerMonitor.computeAdapterInputWatts(
                isPluggedIn: false,
                smcPDTR: 7.8,
                smcVD0R: 19.7,
                smcID0R: 0.4,
                telemetrySystemPowerInMW: 10407,
                telemetryVoltageInMV: 19815,
                telemetryCurrentInMA: 525,
                systemPowerWatts: 8.1,
                batteryPowerMW: -8167
            ) == nil
        )

        // Plugged in prefers SMC PDTR
        let pdtr = try #require(
            PowerMonitor.computeAdapterInputWatts(
                isPluggedIn: true,
                smcPDTR: 7.84,
                smcVD0R: 19.777,
                smcID0R: 0.396,
                telemetrySystemPowerInMW: 10407,
                telemetryVoltageInMV: 19815,
                telemetryCurrentInMA: 525,
                systemPowerWatts: 7.8,
                batteryPowerMW: 0
            )
        )
        #expect(abs(pdtr - 7.84) < 0.001)

        // Fallback to SystemPowerIn when SMC unavailable
        let sysIn = try #require(
            PowerMonitor.computeAdapterInputWatts(
                isPluggedIn: true,
                smcPDTR: nil,
                smcVD0R: nil,
                smcID0R: nil,
                telemetrySystemPowerInMW: 34125,
                telemetryVoltageInMV: 19625,
                telemetryCurrentInMA: 1738,
                systemPowerWatts: 9.76,
                batteryPowerMW: 24368
            )
        )
        #expect(abs(sysIn - 34.125) < 0.001)
    }

    @Test("Outermost .app bundle grouping collapses nested helpers and rejects non-app binaries")
    func outermostAppBundlePathGrouping() {
        #expect(
            PowerMonitor.outermostAppBundlePath(
                from: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/158/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
            ) == "/Applications/Google Chrome.app"
        )
        #expect(
            PowerMonitor.outermostAppBundlePath(
                from: "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/Frameworks/WeChatAppEx Framework.framework/Versions/C/Helpers/WeChatAppEx Helper.app/Contents/MacOS/WeChatAppEx Helper"
            ) == "/Applications/WeChat.app"
        )
        #expect(
            PowerMonitor.outermostAppBundlePath(
                from: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
            ) == "/System/Library/CoreServices/Finder.app"
        )
        #expect(
            PowerMonitor.outermostAppBundlePath(from: "/usr/libexec/replayd") == nil
        )
    }

    @Test("Signed Int64 coercion safely decodes two's-complement UInt64 IOKit discharge counters")
    func signedInt64Decoding() {
        #expect(PowerMonitor.signedInt64Value(UInt64(18446744073709543449)) == -8167)
        #expect(PowerMonitor.signedInt64Value(Int64(24368)) == 24368)
        #expect(PowerMonitor.signedInt64Value(NSNumber(value: -657)) == -657)
        #expect(PowerMonitor.signedInt64Value("invalid") == nil)
    }
}
