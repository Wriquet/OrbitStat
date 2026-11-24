import AppKit
import Darwin
import Foundation
import IOKit

/// Lightweight, non-root macOS System Telemetry service for Apple Silicon & Intel Macs.
///
/// Collects:
/// - CPU die temperature via `AppleSiliconThermal` (IOKit HID + AppleSMC fallback)
/// - Overall & per-core CPU utilization via Mach `host_processor_info` (`PROCESSOR_CPU_LOAD_INFO`)
///   with P-core / E-core labels from IORegistry (`cluster-type`) and `sysctl` (`hw.perflevel*`)
/// - Memory breakdown matching macOS Activity Monitor via Mach `host_statistics64` (`HOST_VM_INFO64`)
///   and `sysctl` (`hw.memsize`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level`, `kern.memorystatus_level`)
/// - Top memory applications grouped by outer `.app` bundle / parent GUI app using
///   `proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_V4)` (`ri_phys_footprint`) with localized display names
/// - System uptime via `sysctl("kern.boottime")`
public actor SystemMonitor: SystemMonitorProtocol {
    // MARK: - Internal Data Types

    private struct CoreTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64
    }

    private struct RunningAppMeta {
        let pid: pid_t
        let bundleIdentifier: String?
        let bundlePath: String?
        let localizedName: String?
    }

    private struct RawProcessEntry {
        let pid: pid_t
        let ppid: pid_t
        let executableName: String
        let executablePath: String
        let footprintBytes: UInt64
    }

    private struct BundleMetadata {
        var displayName: String
        var bundleIdentifier: String?
    }

    private struct MemoryStats {
        let totalBytes: UInt64
        let usedBytes: UInt64
        let compressedBytes: UInt64
        let cachedFilesBytes: UInt64
        let swapUsedBytes: UInt64
        let pressure: MemoryPressureLevel
        let pressureRatio: Double
    }

    private struct CPUMetrics {
        let total: Double
        let user: Double
        let system: Double
        let idle: Double
        let perCore: [CoreUsage]
    }

    // MARK: - Immutable Hardware Metadata

    private let thermal: AppleSiliconThermal
    private let maxReturnedMemoryApps: Int
    private let totalMemoryBytes: UInt64
    private let vmPageSize: UInt64
    private let coreIsPerformance: [Bool?]

    // MARK: - Actor-Isolated Mutable State & Reusable Buffers

    private var previousCPUTicks: [CoreTicks]?
    private var lastCPUSampleUptime: TimeInterval = 0
    private var pidBuffer: [pid_t] = Array(repeating: 0, count: 1024)
    private var pathBuffer: [CChar] = Array(repeating: 0, count: Int(MAXPATHLEN) * 4)
    private var bundleMetadataCache: [String: BundleMetadata] = [:]

    // MARK: - Initialization

    public init() {
        self.thermal = AppleSiliconThermal()
        self.maxReturnedMemoryApps = 50
        self.totalMemoryBytes = Self.readTotalMemoryBytes()
        self.vmPageSize = Self.readVMPageSize()
        self.coreIsPerformance = Self.detectCoreTopology()
        self.previousCPUTicks = Self.readRawCPUTicks()
        self.lastCPUSampleUptime = ProcessInfo.processInfo.systemUptime
    }

    internal init(thermal: AppleSiliconThermal, maxReturnedMemoryApps: Int = 50) {
        self.thermal = thermal
        self.maxReturnedMemoryApps = max(1, maxReturnedMemoryApps)
        self.totalMemoryBytes = Self.readTotalMemoryBytes()
        self.vmPageSize = Self.readVMPageSize()
        self.coreIsPerformance = Self.detectCoreTopology()
        self.previousCPUTicks = Self.readRawCPUTicks()
        self.lastCPUSampleUptime = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - SystemMonitorProtocol

    public func sample() async -> SystemSnapshot {
        let cpu = await sampleCPUMetrics()
        let temperature = thermal.readCPUTemperature()
        let memory = readMemoryStats()
        let topApps = sampleTopMemoryApps()
        let uptime = Self.readUptimeSeconds()

        return SystemSnapshot(
            cpuTemperatureCelsius: temperature,
            cpuTotalUsage: cpu.total,
            cpuUserUsage: cpu.user,
            cpuSystemUsage: cpu.system,
            cpuIdleUsage: cpu.idle,
            perCoreUsage: cpu.perCore,
            memoryUsedBytes: memory.usedBytes,
            memoryTotalBytes: memory.totalBytes,
            memoryCompressedBytes: memory.compressedBytes,
            memoryCachedFilesBytes: memory.cachedFilesBytes,
            swapUsedBytes: memory.swapUsedBytes,
            memoryPressure: memory.pressure,
            memoryPressureRatio: memory.pressureRatio,
            topMemoryApps: topApps,
            uptimeSeconds: uptime,
            timestamp: Date()
        )
    }

    // MARK: - CPU Usage Sampling

    private func sampleCPUMetrics() async -> CPUMetrics {
        let now = ProcessInfo.processInfo.systemUptime
        var current = Self.readRawCPUTicks()

        // Ensure first sample (or back-to-back calls within 50ms) has a real tick delta
        // instead of returning 0% on startup.
        let elapsed = now - lastCPUSampleUptime
        let needsWarmup: Bool
        if let prev = previousCPUTicks, prev.count == current.count, elapsed >= 0.05 {
            needsWarmup = Self.totalTickDelta(from: prev, to: current) == 0
        } else {
            needsWarmup = true
        }

        if needsWarmup {
            previousCPUTicks = current
            lastCPUSampleUptime = now
            try? await Task.sleep(for: .milliseconds(100))
            current = Self.readRawCPUTicks()
        }

        let baseline = previousCPUTicks
        previousCPUTicks = current
        lastCPUSampleUptime = ProcessInfo.processInfo.systemUptime

        guard let prev = baseline, !current.isEmpty, prev.count == current.count else {
            let emptyCores = current.indices.map { idx in
                CoreUsage(id: idx, usage: 0.0, isPerformanceCore: coreLabel(at: idx))
            }
            return CPUMetrics(total: 0, user: 0, system: 0, idle: 100, perCore: emptyCores)
        }

        var sumUser: UInt64 = 0
        var sumSystem: UInt64 = 0
        var sumIdle: UInt64 = 0
        var perCore: [CoreUsage] = []
        perCore.reserveCapacity(current.count)

        for i in 0..<current.count {
            let du = Self.wrappingDelta(from: prev[i].user, to: current[i].user)
            let dn = Self.wrappingDelta(from: prev[i].nice, to: current[i].nice)
            let ds = Self.wrappingDelta(from: prev[i].system, to: current[i].system)
            let di = Self.wrappingDelta(from: prev[i].idle, to: current[i].idle)

            let coreUser = du + dn
            let coreTotal = coreUser + ds + di
            let coreUsage: Double
            if coreTotal > 0 {
                coreUsage = Self.clampPercent((Double(coreUser + ds) / Double(coreTotal)) * 100.0)
            } else {
                coreUsage = 0.0
            }

            perCore.append(CoreUsage(
                id: i,
                usage: coreUsage,
                isPerformanceCore: coreLabel(at: i)
            ))

            sumUser += coreUser
            sumSystem += ds
            sumIdle += di
        }

        let grandTotal = sumUser + sumSystem + sumIdle
        guard grandTotal > 0 else {
            return CPUMetrics(total: 0, user: 0, system: 0, idle: 100, perCore: perCore)
        }

        let totalDouble = Double(grandTotal)
        let userPct = Self.clampPercent((Double(sumUser) / totalDouble) * 100.0)
        let systemPct = Self.clampPercent((Double(sumSystem) / totalDouble) * 100.0)
        let idlePct = Self.clampPercent((Double(sumIdle) / totalDouble) * 100.0)
        let totalPct = Self.clampPercent(userPct + systemPct)

        return CPUMetrics(
            total: totalPct,
            user: userPct,
            system: systemPct,
            idle: idlePct,
            perCore: perCore
        )
    }

    private func coreLabel(at index: Int) -> Bool? {
        guard index >= 0, index < coreIsPerformance.count else { return nil }
        return coreIsPerformance[index]
    }

    private static func readRawCPUTicks() -> [CoreTicks] {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        guard kr == KERN_SUCCESS, let info = cpuInfo else {
            return []
        }

        defer {
            let deallocSize = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), deallocSize)
        }

        let coreCount = Int(numCPUs)
        var ticks: [CoreTicks] = []
        ticks.reserveCapacity(coreCount)

        for i in 0..<coreCount {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            ticks.append(CoreTicks(user: user, system: system, idle: idle, nice: nice))
        }
        return ticks
    }

    private static func wrappingDelta(from previous: UInt64, to current: UInt64) -> UInt64 {
        if current >= previous {
            return current - previous
        }
        // Mach CPU ticks are unsigned 32-bit counters stored in integer_t.
        return (UInt64(UInt32.max) - previous) + current + 1
    }

    private static func totalTickDelta(from previous: [CoreTicks], to current: [CoreTicks]) -> UInt64 {
        var total: UInt64 = 0
        for i in 0..<min(previous.count, current.count) {
            total += wrappingDelta(from: previous[i].user, to: current[i].user)
            total += wrappingDelta(from: previous[i].nice, to: current[i].nice)
            total += wrappingDelta(from: previous[i].system, to: current[i].system)
            total += wrappingDelta(from: previous[i].idle, to: current[i].idle)
        }
        return total
    }

    /// Detects per-core Performance (`true`) vs Efficiency (`false`) topology.
    /// Queries IORegistry `IOPlatformDevice` (`cpu0..cpuN` -> `cluster-type`) first so exact
    /// hardware ordering is preserved (on Apple Silicon, `cpu0..cpu(E-1)` are E-cores and
    /// `cpu(E)..cpu(N-1)` are P/Super-cores), falling back to `hw.perflevel0` / `hw.perflevel1`.
    private static func detectCoreTopology() -> [Bool?] {
        let logicalCPUCount = Int(sysctlInt32("hw.logicalcpu") ?? sysctlInt32("hw.ncpu") ?? 0)
        guard logicalCPUCount > 0 else { return [] }

        var labels = Array<Bool?>(repeating: nil, count: logicalCPUCount)
        var foundFromIORegistry = 0

        if let matching = IOServiceMatching("IOPlatformDevice") {
            var iterator: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                var entry = IOIteratorNext(iterator)
                while entry != 0 {
                    defer {
                        IOObjectRelease(entry)
                        entry = IOIteratorNext(iterator)
                    }

                    var nameBuf = [CChar](repeating: 0, count: 128)
                    guard IORegistryEntryGetName(entry, &nameBuf) == KERN_SUCCESS else { continue }
                    let entryName = String(cString: nameBuf)
                    guard entryName.hasPrefix("cpu") else { continue }

                    let suffix = entryName.dropFirst(3)
                    let digits = suffix.prefix(while: { $0.isNumber })
                    guard let cpuIndex = Int(digits), cpuIndex >= 0, cpuIndex < logicalCPUCount else {
                        continue
                    }

                    if let prop = IORegistryEntryCreateCFProperty(
                        entry,
                        "cluster-type" as CFString,
                        kCFAllocatorDefault,
                        0
                    )?.takeRetainedValue() {
                        if let data = prop as? Data,
                           let typeStr = String(data: data, encoding: .utf8)?
                                .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)) {
                            if typeStr.uppercased().hasPrefix("P") {
                                labels[cpuIndex] = true
                                foundFromIORegistry += 1
                            } else if typeStr.uppercased().hasPrefix("E") {
                                labels[cpuIndex] = false
                                foundFromIORegistry += 1
                            }
                        } else if let str = prop as? String {
                            if str.uppercased().hasPrefix("P") {
                                labels[cpuIndex] = true
                                foundFromIORegistry += 1
                            } else if str.uppercased().hasPrefix("E") {
                                labels[cpuIndex] = false
                                foundFromIORegistry += 1
                            }
                        }
                    }
                }
            }
        }

        if foundFromIORegistry == logicalCPUCount {
            return labels
        }

        // Fallback via sysctl perflevel counts: on Apple Silicon, E-cores (perflevel1) occupy
        // lower CPU indices [0 ..< eCores) and P-cores (perflevel0) occupy [eCores ..< eCores + pCores).
        let perfLevels = Int(sysctlInt32("hw.nperflevels") ?? 1)
        if perfLevels >= 2,
           let pCount = sysctlInt32("hw.perflevel0.logicalcpu").map(Int.init),
           let eCount = sysctlInt32("hw.perflevel1.logicalcpu").map(Int.init),
           pCount > 0, eCount > 0, (pCount + eCount) <= logicalCPUCount {
            for i in 0..<eCount {
                if labels[i] == nil { labels[i] = false }
            }
            for i in eCount..<(eCount + pCount) {
                if labels[i] == nil { labels[i] = true }
            }
        }

        return labels
    }

    // MARK: - Memory Statistics

    private func readMemoryStats() -> MemoryStats {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        var usedBytes: UInt64 = 0
        var compressedBytes: UInt64 = 0
        var cachedFilesBytes: UInt64 = 0

        if kr == KERN_SUCCESS {
            let internalPages = UInt64(vmStats.internal_page_count)
            let purgeablePages = UInt64(vmStats.purgeable_count)
            let wiredPages = UInt64(vmStats.wire_count)
            let compressorPages = UInt64(vmStats.compressor_page_count)
            let externalPages = UInt64(vmStats.external_page_count)

            let appPages = internalPages >= purgeablePages ? (internalPages - purgeablePages) : 0
            compressedBytes = compressorPages &* vmPageSize
            cachedFilesBytes = (externalPages + purgeablePages) &* vmPageSize
            let rawUsed = (appPages + wiredPages + compressorPages) &* vmPageSize
            usedBytes = totalMemoryBytes > 0 ? min(rawUsed, totalMemoryBytes) : rawUsed
        }

        let swapUsedBytes = Self.readSwapUsedBytes()
        let pressure = Self.readMemoryPressureLevel()

        let pressureRatio: Double
        if let freePercent = Self.sysctlInt32("kern.memorystatus_level"),
           freePercent >= 0, freePercent <= 100 {
            pressureRatio = min(1.0, max(0.0, Double(100 - freePercent) / 100.0))
        } else if totalMemoryBytes > 0 {
            pressureRatio = min(1.0, max(0.0, Double(usedBytes) / Double(totalMemoryBytes)))
        } else {
            pressureRatio = 0.0
        }

        return MemoryStats(
            totalBytes: totalMemoryBytes,
            usedBytes: usedBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedFilesBytes,
            swapUsedBytes: swapUsedBytes,
            pressure: pressure,
            pressureRatio: pressureRatio
        )
    }

    private static func readTotalMemoryBytes() -> UInt64 {
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memSize, &size, nil, 0) == 0, memSize > 0 {
            return memSize
        }
        return ProcessInfo.processInfo.physicalMemory
    }

    private static func readVMPageSize() -> UInt64 {
        var pageSize: vm_size_t = 0
        if host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 {
            return UInt64(pageSize)
        }
        let posixPageSize = sysconf(_SC_PAGESIZE)
        return posixPageSize > 0 ? UInt64(posixPageSize) : 16_384
    }

    private static func readSwapUsedBytes() -> UInt64 {
        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0) == 0 else {
            return 0
        }
        return UInt64(swapUsage.xsu_used)
    }

    private static func readMemoryPressureLevel() -> MemoryPressureLevel {
        guard let level = sysctlInt32("kern.memorystatus_vm_pressure_level") else {
            return .normal
        }
        if level >= 4 {
            return .critical
        } else if level >= 2 {
            return .warning
        } else {
            return .normal
        }
    }

    // MARK: - Top Memory Applications

    private func sampleTopMemoryApps() -> [AppMemoryUsage] {
        // Snapshot running GUI / LaunchServices apps for localized names & main PIDs.
        let runningApps = NSWorkspace.shared.runningApplications
        var runningByPid: [pid_t: RunningAppMeta] = [:]
        var runningByBundlePath: [String: RunningAppMeta] = [:]
        runningByPid.reserveCapacity(runningApps.count)
        runningByBundlePath.reserveCapacity(runningApps.count)

        for app in runningApps {
            let meta = RunningAppMeta(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: app.bundleURL?.path,
                localizedName: app.localizedName
            )
            runningByPid[meta.pid] = meta
            if let bp = meta.bundlePath {
                runningByBundlePath[bp] = meta
                if let loc = meta.localizedName, !loc.isEmpty {
                    bundleMetadataCache[bp] = BundleMetadata(
                        displayName: loc,
                        bundleIdentifier: meta.bundleIdentifier
                    )
                }
            }
        }

        // Enumerate all PIDs.
        // IMPORTANT Darwin quirk: `proc_listallpids` returns the COUNT of PIDs, NOT byte count!
        let estimated = Int(proc_listallpids(nil, 0))
        guard estimated > 0 else { return [] }

        let desiredCapacity = max(pidBuffer.count, estimated + 128)
        if pidBuffer.count < desiredCapacity {
            pidBuffer = Array(repeating: 0, count: desiredCapacity)
        }

        var pidCount = Int(proc_listallpids(
            &pidBuffer,
            Int32(pidBuffer.count * MemoryLayout<pid_t>.size)
        ))
        if pidCount >= pidBuffer.count {
            pidBuffer = Array(repeating: 0, count: pidCount + 256)
            pidCount = Int(proc_listallpids(
                &pidBuffer,
                Int32(pidBuffer.count * MemoryLayout<pid_t>.size)
            ))
        }
        guard pidCount > 0 else { return [] }

        // Gather physical footprint, PPID, executable name, and executable path per PID.
        var processes: [pid_t: RawProcessEntry] = [:]
        processes.reserveCapacity(pidCount)

        for index in 0..<min(pidCount, pidBuffer.count) {
            let pid = pidBuffer[index]
            if pid <= 0 { continue }

            var rusage = rusage_info_v4()
            // `proc_pid_rusage` declares `rusage_info_t *` (void **), expecting a direct
            // pointer to the `rusage_info_v4` struct rebound as `rusage_info_t?`.
            let ruResult = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            guard ruResult == 0 else { continue }

            let footprint = rusage.ri_phys_footprint
            guard footprint > 0 else { continue }

            var bsdInfo = proc_bsdinfo()
            let bsdSize = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &bsdInfo,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            let ppid: pid_t = bsdSize > 0 ? pid_t(bsdInfo.pbi_ppid) : 0
            let bsdName = bsdSize > 0 ? Self.extractBSDProcessName(from: &bsdInfo) : ""

            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let execPath = pathLen > 0 ? String(cString: pathBuffer) : ""

            let execName: String
            if !execPath.isEmpty {
                let lastComponent = (execPath as NSString).lastPathComponent
                execName = lastComponent.isEmpty ? bsdName : lastComponent
            } else {
                execName = bsdName
            }
            if execName.isEmpty { continue }

            processes[pid] = RawProcessEntry(
                pid: pid,
                ppid: ppid,
                executableName: execName,
                executablePath: execPath,
                footprintBytes: footprint
            )
        }

        // Group helpers / renderers / extensions into their outer `.app` bundle or parent GUI app.
        struct GroupAccumulator {
            let id: String
            var name: String
            var bundleIdentifier: String?
            var bundlePath: String?
            var primaryPid: pid_t
            var primaryPidFootprint: UInt64
            var hasMainAppPid: Bool
            var totalBytes: UInt64
            var processCount: Int
        }

        var groups: [String: GroupAccumulator] = [:]
        groups.reserveCapacity(128)

        for proc in processes.values {
            var resolvedBundlePath = Self.outerAppBundlePath(for: proc.executablePath)
            var resolvedApp: RunningAppMeta?

            if let bp = resolvedBundlePath {
                resolvedApp = runningByBundlePath[bp]
            } else if let directApp = runningByPid[proc.pid] {
                resolvedApp = directApp
                if let directPath = directApp.bundlePath {
                    resolvedBundlePath = Self.outerAppBundlePath(for: directPath) ?? directPath
                }
            } else {
                // Walk PPID chain up to 8 hops to attribute child helpers outside `.app`
                // (e.g., IDE language servers or bundled workers) to their parent GUI app.
                var cursor = proc.ppid
                var hops = 0
                while cursor > 1, hops < 8 {
                    if let parentApp = runningByPid[cursor], let bp = parentApp.bundlePath {
                        resolvedBundlePath = Self.outerAppBundlePath(for: bp) ?? bp
                        resolvedApp = runningByBundlePath[resolvedBundlePath ?? bp] ?? parentApp
                        break
                    }
                    if let parentProc = processes[cursor] {
                        if let bp = Self.outerAppBundlePath(for: parentProc.executablePath) {
                            resolvedBundlePath = bp
                            resolvedApp = runningByBundlePath[bp]
                            break
                        }
                        cursor = parentProc.ppid
                    } else {
                        break
                    }
                    hops += 1
                }
            }

            let groupID: String
            let displayName: String
            let bundleIdentifier: String?
            let preferredPid: pid_t
            let isMainAppPid: Bool

            if let bp = resolvedBundlePath {
                groupID = "bundle:\(bp)"
                let meta = resolveBundleMetadata(bundlePath: bp, runningApp: resolvedApp)
                displayName = meta.displayName
                bundleIdentifier = meta.bundleIdentifier
                if let app = resolvedApp {
                    preferredPid = app.pid
                    isMainAppPid = (app.pid == proc.pid)
                } else {
                    preferredPid = proc.pid
                    isMainAppPid = false
                }
            } else {
                groupID = "proc:\(proc.executableName)"
                displayName = proc.executableName
                bundleIdentifier = nil
                preferredPid = proc.pid
                isMainAppPid = false
            }

            if var existing = groups[groupID] {
                existing.totalBytes += proc.footprintBytes
                existing.processCount += 1
                if isMainAppPid {
                    existing.primaryPid = preferredPid
                    existing.hasMainAppPid = true
                } else if !existing.hasMainAppPid, proc.footprintBytes > existing.primaryPidFootprint {
                    existing.primaryPid = preferredPid
                    existing.primaryPidFootprint = proc.footprintBytes
                }
                if existing.bundleIdentifier == nil, let bid = bundleIdentifier {
                    existing.bundleIdentifier = bid
                }
                groups[groupID] = existing
            } else {
                groups[groupID] = GroupAccumulator(
                    id: groupID,
                    name: displayName,
                    bundleIdentifier: bundleIdentifier,
                    bundlePath: resolvedBundlePath,
                    primaryPid: preferredPid,
                    primaryPidFootprint: proc.footprintBytes,
                    hasMainAppPid: isMainAppPid,
                    totalBytes: proc.footprintBytes,
                    processCount: 1
                )
            }
        }

        let sorted = groups.values.sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes {
                return lhs.totalBytes > rhs.totalBytes
            }
            return lhs.name < rhs.name
        }

        return sorted.prefix(maxReturnedMemoryApps).map { g in
            AppMemoryUsage(
                id: g.id,
                name: g.name,
                bundleIdentifier: g.bundleIdentifier,
                bundlePath: g.bundlePath,
                pid: g.primaryPid,
                bytes: g.totalBytes,
                processCount: g.processCount
            )
        }
    }

    private func resolveBundleMetadata(
        bundlePath: String,
        runningApp: RunningAppMeta?
    ) -> BundleMetadata {
        if let app = runningApp, let loc = app.localizedName, !loc.isEmpty {
            let meta = BundleMetadata(
                displayName: loc,
                bundleIdentifier: app.bundleIdentifier ?? bundleMetadataCache[bundlePath]?.bundleIdentifier
            )
            bundleMetadataCache[bundlePath] = meta
            return meta
        }

        if let cached = bundleMetadataCache[bundlePath] {
            return cached
        }

        let rawDisplayName = FileManager.default.displayName(atPath: bundlePath)
        let cleanedName: String
        if rawDisplayName.hasSuffix(".app") {
            cleanedName = String(rawDisplayName.dropLast(4))
        } else if rawDisplayName.hasSuffix(".xpc") {
            cleanedName = String(rawDisplayName.dropLast(4))
        } else {
            cleanedName = rawDisplayName
        }

        let bundleID = runningApp?.bundleIdentifier ?? Bundle(path: bundlePath)?.bundleIdentifier
        let finalName = cleanedName.isEmpty
            ? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            : cleanedName

        let meta = BundleMetadata(displayName: finalName, bundleIdentifier: bundleID)
        bundleMetadataCache[bundlePath] = meta
        return meta
    }

    /// Walks path components from the root and returns the outermost `.app` bundle path,
    /// collapsing nested helpers (e.g. `.../Microsoft Edge.app/Contents/Frameworks/...Helper.app/...`
    /// -> `.../Microsoft Edge.app`).
    internal static func outerAppBundlePath(for path: String) -> String? {
        guard !path.isEmpty, path.contains(".app") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var built = ""
        built.reserveCapacity(path.count)
        for component in components {
            built.append("/")
            built.append(contentsOf: component)
            if component.hasSuffix(".app") {
                return built
            }
        }
        return nil
    }

    private static func extractBSDProcessName(from info: inout proc_bsdinfo) -> String {
        let primary = withUnsafeBytes(of: &info.pbi_name) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        if !primary.isEmpty {
            return primary
        }
        return withUnsafeBytes(of: &info.pbi_comm) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - Uptime & Sysctl Helpers

    private static func readUptimeSeconds() -> TimeInterval {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let bootEpoch = Double(bootTime.tv_sec) + (Double(bootTime.tv_usec) / 1_000_000.0)
        return max(0.0, Date().timeIntervalSince1970 - bootEpoch)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(100.0, max(0.0, value))
    }
}
