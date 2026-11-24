import Foundation
import Testing
@testable import OrbitStat

@Suite("SystemMonitor & AppleSiliconThermal Tests")
struct SystemMonitorTests {
    // MARK: - Thermal Sensor Classification & Live Readings

    @Test("IOHID sensor classification selects CPU die sensors and rejects non-CPU sensors")
    func hidSensorClassification() {
        // Dedicated Apple Silicon CPU cluster MTR sensors (Tier 1)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "pACC MTR Temp Sensor0") == 1)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "eACC MTR Temp Sensor3") == 1)

        // Apple Silicon PMU / SoC CPU die sensors (Tier 2)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "PMU tdie1") == 2)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "PMU2 tdie10") == 2)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "SOC MTR Temp Sensor0") == 2)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "CPU die temperature") == 2)

        // Non-CPU / bogus / calibration sensors must be rejected
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "PMU tdev1") == nil)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "PMU tcal") == nil)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "PMU2 tcal") == nil)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "gas gauge battery") == nil)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "NAND CH0 temp") == nil)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "GPU MTR Temp Sensor1") == nil)
        #expect(AppleSiliconThermal.classifyHIDSensor(name: "als-temp") == nil)
    }

    @Test("AppleSiliconThermal reads realistic CPU temperature without root via IOHID and SMC")
    func liveAppleSiliconThermalHIDAndSMCFallback() throws {
        let thermal = AppleSiliconThermal()

        let primaryTemp = try #require(
            thermal.readCPUTemperature(),
            "Expected real non-root CPU temperature on this Mac"
        )
        #expect(primaryTemp > 15.0)
        #expect(primaryTemp < 115.0)

        let hidSensors = thermal.readAllHIDCPUSensors()
        #expect(!hidSensors.isEmpty)
        for sensor in hidSensors {
            #expect(sensor.source == .hid)
            #expect(sensor.celsius > 0.5)
            #expect(sensor.celsius < 120.0)
            #expect(!sensor.name.lowercased().contains("tdev"))
            #expect(!sensor.name.lowercased().contains("tcal"))
        }

        // Verify cached HID client continues returning realistic values on repeat polls
        let secondHID = try #require(thermal.readHIDCPUTemperature())
        #expect(secondHID > 15.0)
        #expect(secondHID < 115.0)

        // Verify AppleSMC fallback path works without root as well
        if let smcTemp = thermal.readSMCCPUTemperature() {
            #expect(smcTemp > 15.0)
            #expect(smcTemp < 115.0)
        }
    }

    // MARK: - Bundle Grouping Helper

    @Test("Outer .app bundle extraction collapses nested helpers and preserves CLI binaries")
    func outerAppBundlePathExtraction() {
        let edgeHelper = "/Applications/Microsoft Edge.app/Contents/Frameworks/Microsoft Edge Framework.framework/Versions/130.0/Helpers/Microsoft Edge Helper (Renderer).app/Contents/MacOS/Microsoft Edge Helper (Renderer)"
        #expect(
            SystemMonitor.outerAppBundlePath(for: edgeHelper) == "/Applications/Microsoft Edge.app"
        )

        let weChatExt = "/Applications/WeChat.app/Contents/PlugIns/WeChatShare.appex/Contents/MacOS/WeChatShare"
        #expect(
            SystemMonitor.outerAppBundlePath(for: weChatExt) == "/Applications/WeChat.app"
        )

        let nestedFolderApp = "/Applications/OpenVPN Connect/OpenVPN Connect.app/Contents/MacOS/OpenVPN Connect"
        #expect(
            SystemMonitor.outerAppBundlePath(for: nestedFolderApp) == "/Applications/OpenVPN Connect/OpenVPN Connect.app"
        )

        #expect(SystemMonitor.outerAppBundlePath(for: "/usr/bin/python3.12") == nil)
        #expect(SystemMonitor.outerAppBundlePath(for: "") == nil)
    }

    // MARK: - Live SystemMonitor Sampling

    @Test("SystemMonitor produces consistent live CPU, temperature, memory, uptime, and app metrics")
    func liveSystemMonitorSnapshotConsistency() async throws {
        let monitor = SystemMonitor()

        // First sample should warm up cleanly and produce a real live snapshot.
        let first = await monitor.sample()

        // Generate a brief burst of CPU work so subsequent sample is guaranteed non-zero.
        let workTask = Task.detached(priority: .userInitiated) {
            var acc: UInt64 = 0
            for i in 1..<250_000 {
                acc = acc &+ UInt64(i &* 31)
            }
            return acc
        }
        _ = await workTask.value
        try? await Task.sleep(for: .milliseconds(150))

        let sampleStart = CFAbsoluteTimeGetCurrent()
        let snapshot = await monitor.sample()
        let sampleDurationMs = (CFAbsoluteTimeGetCurrent() - sampleStart) * 1000.0

        // 1. CPU Temperature
        let temp = try #require(
            snapshot.cpuTemperatureCelsius,
            "Expected live CPU die temperature"
        )
        #expect(temp > 15.0)
        #expect(temp < 115.0)

        // 2. CPU Usage & Per-Core Topology
        #expect(first.cpuTotalUsage >= 0.0)
        #expect(first.cpuTotalUsage <= 100.0)
        #expect(snapshot.cpuTotalUsage > 0.0)
        #expect(snapshot.cpuTotalUsage <= 100.0)
        #expect(snapshot.cpuUserUsage >= 0.0)
        #expect(snapshot.cpuSystemUsage >= 0.0)
        #expect(snapshot.cpuIdleUsage >= 0.0)
        let breakdownSum = snapshot.cpuUserUsage + snapshot.cpuSystemUsage + snapshot.cpuIdleUsage
        #expect(abs(breakdownSum - 100.0) <= 1.5)

        let expectedCores = ProcessInfo.processInfo.processorCount
        #expect(snapshot.perCoreUsage.count == expectedCores)
        for (idx, core) in snapshot.perCoreUsage.enumerated() {
            #expect(core.id == idx)
            #expect(core.usage >= 0.0)
            #expect(core.usage <= 100.0)
        }

        // On Apple Silicon (2 perf levels), verify both P-cores and E-cores are labeled.
        var perfLevels: Int32 = 0
        var perfSize = MemoryLayout<Int32>.size
        if sysctlbyname("hw.nperflevels", &perfLevels, &perfSize, nil, 0) == 0, perfLevels >= 2 {
            let pCores = snapshot.perCoreUsage.filter { $0.isPerformanceCore == true }.count
            let eCores = snapshot.perCoreUsage.filter { $0.isPerformanceCore == false }.count
            #expect(pCores > 0)
            #expect(eCores > 0)
            #expect(pCores + eCores == expectedCores)
        }

        // 3. Memory Consistency
        #expect(snapshot.memoryTotalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(snapshot.memoryUsedBytes > 0)
        #expect(snapshot.memoryUsedBytes <= snapshot.memoryTotalBytes)
        #expect(snapshot.memoryCompressedBytes <= snapshot.memoryUsedBytes)
        #expect(snapshot.memoryCachedFilesBytes <= snapshot.memoryTotalBytes)
        #expect(snapshot.memoryPressureRatio >= 0.0)
        #expect(snapshot.memoryPressureRatio <= 1.0)
        #expect(snapshot.memoryUsagePercent > 0.0)
        #expect(snapshot.memoryUsagePercent <= 100.0)

        // 4. Uptime
        #expect(snapshot.uptimeSeconds > 1.0)

        // 5. Grouped Top Memory Apps
        #expect(!snapshot.topMemoryApps.isEmpty)
        var seenIDs = Set<String>()
        var previousBytes = UInt64.max
        for app in snapshot.topMemoryApps {
            #expect(!app.name.isEmpty)
            #expect(app.bytes > 0)
            #expect(app.processCount >= 1)
            #expect(app.pid > 0)
            #expect(seenIDs.insert(app.id).inserted)
            #expect(app.bytes <= previousBytes)
            previousBytes = app.bytes
        }

        // 6. Low overhead steady-state sampling latency
        #expect(sampleDurationMs < 500.0)
    }
}
