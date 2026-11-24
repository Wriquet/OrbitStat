import CoreFoundation
import Darwin
import Foundation
import IOKit

/// Source backend used to obtain a thermal sensor reading.
public enum ThermalSource: String, Equatable, Sendable {
    case hid
    case smc
}

/// Individual thermal sensor reading in degrees Celsius.
public struct ThermalSensorReading: Equatable, Sendable {
    public let name: String
    public let celsius: Double
    public let source: ThermalSource

    public init(name: String, celsius: Double, source: ThermalSource) {
        self.name = name
        self.celsius = celsius
        self.source = source
    }
}

/// Non-root Apple Silicon CPU die temperature reader.
///
/// Primary backend: dynamically loaded IOKit private HID Event System APIs
/// (`PrimaryUsagePage = 0xFF00`, `PrimaryUsage = 5`, `kIOHIDEventTypeTemperature = 15`).
/// Fallback backend: `AppleSMC` user-client reads (`Tp*`/`Te*` on Apple Silicon, `TC*` on Intel).
public final class AppleSiliconThermal: @unchecked Sendable {
    // MARK: - Constants

    private static let hidPageAppleVendor: Int = 0xFF00
    private static let hidUsageSensor: Int = 5
    private static let hidEventTypeTemperature: Int64 = 15
    private static let hidEventFieldTemperatureLevel: Int32 = 15 << 16

    private static let validTemperatureRange: ClosedRange<Double> = 0.5 ... 120.0

    // MARK: - Dynamic HID Function Types (Explicit Unmanaged for +1 Create/Copy CF Ownership)

    private typealias CreateClientFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private struct HIDSymbols {
        let createClient: CreateClientFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let getFloatValue: GetFloatValueFn
    }

    private struct CachedHIDSensor {
        let name: String
        let service: CFTypeRef
        let tier: Int // 1 = dedicated CPU cluster MTR (eACC/pACC), 2 = PMU/SoC die (tdie/SOC MTR)
    }

    // MARK: - AppleSMC Structures (Exact 80-byte ARM64/x86_64 SMCParamStruct Layout)

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
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
    }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private struct CachedSMCKey {
        let name: String
        let key: UInt32
        let dataSize: UInt32
        let dataType: UInt32
        let tier: Int // 1 = Apple Silicon CPU P/E cores (Tp*/Te*), 2 = fallback CPU/PMU keys
    }

    private static let smcSelectorHandleYPCEvent: UInt32 = 2
    private static let smcCmdReadKey: UInt8 = 5
    private static let smcCmdGetKeyFromIndex: UInt8 = 8
    private static let smcCmdGetKeyInfo: UInt8 = 9
    private static let smcTypeFloat: UInt32 = fourCC("flt ")
    private static let smcTypeSP78: UInt32 = fourCC("sp78")

    // MARK: - Protected Mutable State

    private let lock = NSLock()
    private var iokitHandle: UnsafeMutableRawPointer?
    private var hidSymbols: HIDSymbols?
    private var hidLoadAttempted = false
    private var hidClient: CFTypeRef?
    private var cachedHIDSensors: [CachedHIDSensor]?

    private var smcConnection: io_connect_t = 0
    private var smcDiscoveryAttempted = false
    private var cachedSMCKeys: [CachedSMCKey] = []

    // MARK: - Lifecycle

    public init() {}

    deinit {
        lock.lock()
        defer { lock.unlock() }
        cachedHIDSensors = nil
        hidClient = nil
        if smcConnection != 0 {
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
        if let handle = iokitHandle {
            dlclose(handle)
            iokitHandle = nil
        }
    }

    // MARK: - Public API

    /// Returns the averaged CPU die temperature in Celsius, trying IOHID first and AppleSMC as fallback.
    public func readCPUTemperature() -> Double? {
        if let hidTemp = readHIDCPUTemperature() {
            return hidTemp
        }
        return readSMCCPUTemperature()
    }

    /// Reads CPU die temperature solely from IOKit HID private temperature sensors.
    public func readHIDCPUTemperature() -> Double? {
        lock.lock()
        defer { lock.unlock() }

        let readings = readHIDCPUSensorsLocked()
        return Self.averagePreferredReadings(readings)
    }

    /// Reads all matched HID CPU die sensor readings (for diagnostics and tests).
    public func readAllHIDCPUSensors() -> [ThermalSensorReading] {
        lock.lock()
        defer { lock.unlock() }
        return readHIDCPUSensorsLocked().map { $0.reading }
    }

    /// Reads CPU die temperature solely from AppleSMC as a non-root fallback.
    public func readSMCCPUTemperature() -> Double? {
        lock.lock()
        defer { lock.unlock() }

        let readings = readSMCCPUSensorsLocked()
        return Self.averagePreferredReadings(readings)
    }

    /// Reads all matched AppleSMC CPU temperature sensor readings (for diagnostics and tests).
    public func readAllSMCCPUSensors() -> [ThermalSensorReading] {
        lock.lock()
        defer { lock.unlock() }
        return readSMCCPUSensorsLocked().map { $0.reading }
    }

    // MARK: - HID Implementation

    private func loadHIDSymbolsLocked() -> HIDSymbols? {
        if hidLoadAttempted {
            return hidSymbols
        }
        hidLoadAttempted = true

        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        iokitHandle = handle

        guard
            let pCreate = dlsym(handle, "IOHIDEventSystemClientCreate"),
            let pSetMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
            let pCopyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
            let pCopyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
            let pCopyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
            let pGetFloat = dlsym(handle, "IOHIDEventGetFloatValue")
        else {
            return nil
        }

        let symbols = HIDSymbols(
            createClient: unsafeBitCast(pCreate, to: CreateClientFn.self),
            setMatching: unsafeBitCast(pSetMatching, to: SetMatchingFn.self),
            copyServices: unsafeBitCast(pCopyServices, to: CopyServicesFn.self),
            copyProperty: unsafeBitCast(pCopyProperty, to: CopyPropertyFn.self),
            copyEvent: unsafeBitCast(pCopyEvent, to: CopyEventFn.self),
            getFloatValue: unsafeBitCast(pGetFloat, to: GetFloatValueFn.self)
        )
        hidSymbols = symbols
        return symbols
    }

    private func ensureHIDClientLocked(_ symbols: HIDSymbols) -> CFTypeRef? {
        if let existing = hidClient {
            return existing
        }
        guard let client = symbols.createClient(kCFAllocatorDefault)?.takeRetainedValue() else {
            return nil
        }
        let matching: [String: Any] = [
            "PrimaryUsagePage": Self.hidPageAppleVendor,
            "PrimaryUsage": Self.hidUsageSensor
        ]
        symbols.setMatching(client, matching as CFDictionary)
        hidClient = client
        return client
    }

    private func discoverHIDSensorsLocked(_ symbols: HIDSymbols, client: CFTypeRef) -> [CachedHIDSensor] {
        guard let servicesArray = symbols.copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return []
        }

        var discovered: [CachedHIDSensor] = []
        discovered.reserveCapacity(servicesArray.count)

        for svc in servicesArray {
            let serviceRef: CFTypeRef = svc
            guard
                let nameObj = symbols.copyProperty(serviceRef, "Product" as CFString)?.takeRetainedValue(),
                let name = nameObj as? String,
                let tier = Self.classifyHIDSensor(name: name)
            else {
                continue
            }
            discovered.append(CachedHIDSensor(name: name, service: serviceRef, tier: tier))
        }
        return discovered
    }

    private func readHIDCPUSensorsLocked() -> [(tier: Int, reading: ThermalSensorReading)] {
        guard let symbols = loadHIDSymbolsLocked(),
              let client = ensureHIDClientLocked(symbols) else {
            return []
        }

        if cachedHIDSensors == nil {
            cachedHIDSensors = discoverHIDSensorsLocked(symbols, client: client)
        }

        var results = sampleCachedHIDSensorsLocked(symbols, sensors: cachedHIDSensors ?? [])
        if results.isEmpty {
            // Re-discover once in case HID services were reset (e.g., after sleep/wake).
            hidClient = nil
            cachedHIDSensors = nil
            if let freshClient = ensureHIDClientLocked(symbols) {
                let freshSensors = discoverHIDSensorsLocked(symbols, client: freshClient)
                cachedHIDSensors = freshSensors
                results = sampleCachedHIDSensorsLocked(symbols, sensors: freshSensors)
            }
        }
        return results
    }

    private func sampleCachedHIDSensorsLocked(
        _ symbols: HIDSymbols,
        sensors: [CachedHIDSensor]
    ) -> [(tier: Int, reading: ThermalSensorReading)] {
        var results: [(tier: Int, reading: ThermalSensorReading)] = []
        results.reserveCapacity(sensors.count)

        for sensor in sensors {
            guard let event = symbols.copyEvent(
                sensor.service,
                Self.hidEventTypeTemperature,
                0,
                0
            )?.takeRetainedValue() else {
                continue
            }
            let celsius = symbols.getFloatValue(event, Self.hidEventFieldTemperatureLevel)
            guard celsius.isFinite, Self.validTemperatureRange.contains(celsius) else {
                continue
            }
            results.append((
                tier: sensor.tier,
                reading: ThermalSensorReading(name: sensor.name, celsius: celsius, source: .hid)
            ))
        }
        return results
    }

    /// Classifies an IOHID temperature sensor name.
    /// Returns tier 1 for dedicated CPU cluster MTR sensors (`pACC`/`eACC`),
    /// tier 2 for Apple Silicon PMU/SoC CPU die sensors (`PMU tdie`, `PMU2 tdie`, `SOC MTR`, `CPU die`),
    /// or `nil` for non-CPU / calibration / bogus sensors.
    internal static func classifyHIDSensor(name: String) -> Int? {
        let lower = name.lowercased()

        // Explicitly reject calibration, board/device, battery, storage, GPU/ANE, and peripheral sensors.
        let excludedTokens = [
            "tdev", "tcal", "battery", "gas gauge", "nand", "ssd", "als",
            "charger", "gpu", "ane", "dram", "airflow", "palm", "trackpad",
            "display", "backlight", "wireless", "wifi", "bluetooth"
        ]
        for token in excludedTokens {
            if lower.contains(token) {
                return nil
            }
        }

        // Tier 1: Dedicated Apple Silicon CPU cluster MTR sensors (e.g., M1/M2 eACC/pACC).
        if lower.contains("pacc") || lower.contains("eacc") {
            return 1
        }

        // Tier 2: Apple Silicon PMU / SoC CPU die sensors (M1-M5 PMU tdie*, PMU2 tdie*, SOC MTR, CPU die).
        if lower.contains("tdie") || lower.contains("soc mtr") {
            return 2
        }
        if lower.contains("cpu") && (lower.contains("die") || lower.contains("temp") || lower.contains("mtr")) {
            return 2
        }
        return nil
    }

    // MARK: - AppleSMC Fallback Implementation

    private func ensureSMCConnectionLocked() -> io_connect_t? {
        if smcConnection != 0 {
            return smcConnection
        }
        guard let matching = IOServiceMatching("AppleSMC") else {
            return nil
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0 else {
            return nil
        }
        smcConnection = conn
        return conn
    }

    private func callSMCLocked(_ conn: io_connect_t, input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let kr = IOConnectCallStructMethod(
            conn,
            Self.smcSelectorHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )
        guard kr == KERN_SUCCESS else {
            return nil
        }
        return output
    }

    private func discoverSMCKeysLocked(_ conn: io_connect_t) {
        if smcDiscoveryAttempted {
            return
        }
        smcDiscoveryAttempted = true

        // Read total SMC key count from #KEY.
        var countInfoIn = SMCParamStruct()
        countInfoIn.key = Self.fourCC("#KEY")
        countInfoIn.data8 = Self.smcCmdGetKeyInfo
        guard let countInfoOut = callSMCLocked(conn, input: &countInfoIn) else {
            return
        }

        var countReadIn = SMCParamStruct()
        countReadIn.key = countInfoIn.key
        countReadIn.keyInfo.dataSize = countInfoOut.keyInfo.dataSize
        countReadIn.data8 = Self.smcCmdReadKey
        guard let countReadOut = callSMCLocked(conn, input: &countReadIn) else {
            return
        }

        let keyCount = (UInt32(countReadOut.bytes.0) << 24)
            | (UInt32(countReadOut.bytes.1) << 16)
            | (UInt32(countReadOut.bytes.2) << 8)
            | UInt32(countReadOut.bytes.3)
        guard keyCount > 0, keyCount < 100_000 else {
            return
        }

        var keys: [CachedSMCKey] = []
        let fallbackCPUKeys: Set<String> = ["TC0P", "TC0D", "TC0E", "TC0F", "TCXC", "TC0C", "TPDX"]

        for index in 0..<keyCount {
            var idxIn = SMCParamStruct()
            idxIn.data8 = Self.smcCmdGetKeyFromIndex
            idxIn.data32 = index
            guard let idxOut = callSMCLocked(conn, input: &idxIn) else {
                continue
            }
            let keyName = Self.fromFourCC(idxOut.key)
            let tier: Int
            if keyName.hasPrefix("Tp") || keyName.hasPrefix("Te") {
                tier = 1
            } else if fallbackCPUKeys.contains(keyName) {
                tier = 2
            } else {
                continue
            }

            var infoIn = SMCParamStruct()
            infoIn.key = idxOut.key
            infoIn.data8 = Self.smcCmdGetKeyInfo
            guard let infoOut = callSMCLocked(conn, input: &infoIn) else {
                continue
            }

            let dt = infoOut.keyInfo.dataType
            guard dt == Self.smcTypeFloat || dt == Self.smcTypeSP78 else {
                continue
            }

            keys.append(CachedSMCKey(
                name: keyName,
                key: idxOut.key,
                dataSize: infoOut.keyInfo.dataSize,
                dataType: dt,
                tier: tier
            ))
        }

        cachedSMCKeys = keys
    }

    private func readSMCCPUSensorsLocked() -> [(tier: Int, reading: ThermalSensorReading)] {
        guard let conn = ensureSMCConnectionLocked() else {
            return []
        }
        discoverSMCKeysLocked(conn)

        var results: [(tier: Int, reading: ThermalSensorReading)] = []
        results.reserveCapacity(cachedSMCKeys.count)

        for entry in cachedSMCKeys {
            var readIn = SMCParamStruct()
            readIn.key = entry.key
            readIn.keyInfo.dataSize = entry.dataSize
            readIn.data8 = Self.smcCmdReadKey
            guard let readOut = callSMCLocked(conn, input: &readIn) else {
                continue
            }

            let celsius: Double?
            if entry.dataType == Self.smcTypeFloat, entry.dataSize == 4 {
                let bits: UInt32 = UInt32(readOut.bytes.0)
                    | (UInt32(readOut.bytes.1) << 8)
                    | (UInt32(readOut.bytes.2) << 16)
                    | (UInt32(readOut.bytes.3) << 24)
                celsius = Double(Float(bitPattern: bits))
            } else if entry.dataType == Self.smcTypeSP78, entry.dataSize == 2 {
                let raw = Int16(bitPattern: (UInt16(readOut.bytes.0) << 8) | UInt16(readOut.bytes.1))
                celsius = Double(raw) / 256.0
            } else {
                celsius = nil
            }

            if let celsius, celsius.isFinite, Self.validTemperatureRange.contains(celsius) {
                results.append((
                    tier: entry.tier,
                    reading: ThermalSensorReading(name: entry.name, celsius: celsius, source: .smc)
                ))
            }
        }
        return results
    }

    // MARK: - Helpers

    private static func averagePreferredReadings(
        _ readings: [(tier: Int, reading: ThermalSensorReading)]
    ) -> Double? {
        guard !readings.isEmpty else { return nil }
        let tier1 = readings.filter { $0.tier == 1 }
        let selected = tier1.isEmpty ? readings : tier1
        let sum = selected.reduce(0.0) { $0 + $1.reading.celsius }
        return sum / Double(selected.count)
    }

    private static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private static func fromFourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
