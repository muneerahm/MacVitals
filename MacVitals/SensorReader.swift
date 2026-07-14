//
//  SensorReader.swift
//  MacVitals
//
//  All hardware-sensor access for Apple Silicon lives here.
//
//  A note on APIs — and why there are three of them:
//
//  1. Temperatures  → IOKit HID (IOHIDEventSystemClient).
//     On M-series Macs the die/cluster temperature sensors are published as
//     HID services (usage page 0xFF00 / usage 0x0005, kIOHIDEventTypeTemperature).
//     This is what exelban/stats' Sensors module, TG Pro and socpowerbud use.
//     The old Intel SMC temp keys (TC0P, ...) mostly don't exist on M-series.
//
//  2. Fan RPM       → AppleSMC user client.
//     IOReport does NOT expose fan tachometers. Even on Apple Silicon the fans
//     are still reported by the SMC under the classic FNum / F%dAc / F%dMn /
//     F%dMx keys — the only difference is the value type is 'flt ' (LE float)
//     instead of Intel's 'fpe2'. This is exactly what Macs Fan Control and
//     stats do on M-series. Both cases are handled below.
//
//  3. CPU/GPU power → IOReport ("Energy Model" group).
//     Included because it's the one thing IOReport is genuinely the right API
//     for on M-series: per-block energy counters, sampled as deltas.
//
//  All three use private C symbols. HID and IOReport entry points are resolved
//  at runtime so missing symbols degrade to unavailable data instead of a
//  launch-time linker failure.
//
//  ⚠️ Sandbox: every call in this file fails inside the App Sandbox.
//     See README.md → "Sandboxing & entitlements".
//

import Foundation
import IOKit
import CoreFoundation

// MARK: - Private IOKit HID symbols (temperature sensors)

/// Resolve private HID entry points at runtime so a removed symbol degrades to
/// unavailable temperatures instead of preventing the process from launching.
private enum HID {
    typealias CreateClientFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    typealias SetMatchingFn = @convention(c) (OpaquePointer?, CFDictionary?) -> Int32
    typealias CopyServicesFn = @convention(c) (OpaquePointer?) -> Unmanaged<CFArray>?
    typealias CopyPropertyFn = @convention(c) (OpaquePointer?, CFString?) -> Unmanaged<CFTypeRef>?
    typealias CopyEventFn = @convention(c) (OpaquePointer?, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    typealias GetFloatValueFn = @convention(c) (CFTypeRef?, Int32) -> Double

    private static let handle = dlopen(
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
        RTLD_LAZY | RTLD_LOCAL
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    static let createClient = symbol("IOHIDEventSystemClientCreate", as: CreateClientFn.self)
    static let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self)
    static let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self)
    static let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self)
    static let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self)
    static let getFloatValue = symbol("IOHIDEventGetFloatValue", as: GetFloatValueFn.self)
}

private let kIOHIDEventTypeTemperature: Int64 = 15
private let kIOHIDEventFieldTemperatureLevel: Int32 = Int32(15 << 16)
private let kHIDPageAppleVendor = 0xFF00
private let kHIDUsageAppleVendorTemperatureSensor = 0x0005

// MARK: - Private IOReport symbols (energy counters)
//
// Unlike the IOHID* functions above (exported by IOKit.framework), the
// IOReport* functions live in
// /usr/lib/libIOReport.dylib and the macOS SDK ships NO link-time stub for
// them → "@_silgen_name" produces "Undefined symbol: _IOReport..." at link.
// So these are resolved at runtime with dlopen/dlsym instead.

private enum IOReport {
    typealias CopyChannelsInGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias CreateSubscriptionFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    typealias CreateSamplesFn = @convention(c) (OpaquePointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDeltaFn = @convention(c) (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelGetStringFn = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    typealias SimpleGetIntegerValueFn = @convention(c) (CFDictionary?, Int32) -> Int64
    typealias IterateFn = @convention(c) (CFDictionary?, @convention(block) (CFDictionary?) -> Int32) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static let copyChannelsInGroup = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsInGroupFn.self)
    static let createSubscription = symbol("IOReportCreateSubscription", as: CreateSubscriptionFn.self)
    static let createSamples = symbol("IOReportCreateSamples", as: CreateSamplesFn.self)
    static let createSamplesDelta = symbol("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self)
    static let channelGetChannelName = symbol("IOReportChannelGetChannelName", as: ChannelGetStringFn.self)
    static let channelGetUnitLabel = symbol("IOReportChannelGetUnitLabel", as: ChannelGetStringFn.self)
    static let simpleGetIntegerValue = symbol("IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValueFn.self)
    static let iterate = symbol("IOReportIterate", as: IterateFn.self)

    static var isAvailable: Bool {
        copyChannelsInGroup != nil && createSubscription != nil && createSamples != nil
            && createSamplesDelta != nil && channelGetChannelName != nil
            && channelGetUnitLabel != nil && simpleGetIntegerValue != nil && iterate != nil
    }
}

enum EnergyUnitDecoder {
    static func joules(raw: Double, unit: String) -> Double? {
        guard raw.isFinite else { return nil }
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "J": return raw
        case "mJ": return raw * 1e-3
        case "uJ", "µJ": return raw * 1e-6
        case "nJ": return raw * 1e-9
        case "pJ": return raw * 1e-12
        default: return nil
        }
    }
}

// MARK: - SMC (fan RPM)

/// Classic AppleSMC user-client protocol. Layout must match the kernel's
/// SMCParamStruct (80 bytes) exactly.
struct SMCParamStruct {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    // AppleSMC's SMCKeyData_t has a 2-byte gap here that Swift won't insert on
    // its own. Without it the struct is 76 bytes and IOConnectCallStructMethod
    // rejects every call with kIOReturnBadArgument (0xe00002c2). With it the
    // struct is the 80 bytes the kernel expects, and field offsets line up.
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
               (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private enum SMCSelector {
    static let handleYPCEvent: UInt32 = 2
    static let readKey: UInt8 = 5
    static let getKeyFromIndex: UInt8 = 8
    static let getKeyInfo: UInt8 = 9
}

enum SMCValueDecoder {
    static func decode(type: String, bytes b: [UInt8]) -> Double? {
        guard !b.isEmpty else { return nil }
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let value = Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            guard value.isFinite else { return nil }
            return Double(value)
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "ui8 ":
            return Double(b[0])
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        default:
            return nil
        }
    }
}

private final class SMCConnection {
    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        // ⚠️ IOServiceOpen on AppleSMC returns kIOReturnNotPermitted inside the
        // App Sandbox unless a temporary-exception entitlement is granted.
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(connection,
                                               SMCSelector.handleYPCEvent,
                                               &input, MemoryLayout<SMCParamStruct>.stride,
                                               &output, &outputSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    /// Reads a key, returning its 4CC type string and raw bytes.
    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let keyCode = Self.fourCC(key)
        guard keyCode != 0 else { return nil }

        var infoIn = SMCParamStruct()
        infoIn.key = keyCode
        infoIn.data8 = SMCSelector.getKeyInfo
        guard let info = call(&infoIn) else { return nil }

        var readIn = SMCParamStruct()
        readIn.key = keyCode
        readIn.keyInfo.dataSize = info.keyInfo.dataSize
        readIn.data8 = SMCSelector.readKey
        guard let out = call(&readIn) else { return nil }

        let size = Int(min(info.keyInfo.dataSize, 32))
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        return (Self.string(fromFourCC: info.keyInfo.dataType), bytes)
    }

    func readNumber(_ key: String) -> Double? {
        guard let (type, bytes) = read(key) else { return nil }
        return SMCValueDecoder.decode(type: type, bytes: bytes)
    }

    /// Enumerate every SMC key by index. Apple Silicon exposes no fixed list
    /// of die-temperature keys (they vary by chip: Tp/Te = CPU cores, Tg = GPU,
    /// Ts = SoC), so we enumerate and let the caller filter by prefix.
    func allKeys() -> [String] {
        guard let reportedTotal = readNumber("#KEY"),
              let total = Int(exactly: reportedTotal),
              total > 0, total <= 65_536 else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(total)
        for i in 0..<total {
            var input = SMCParamStruct()
            input.data8 = SMCSelector.getKeyFromIndex
            input.data32 = UInt32(i)
            guard let out = call(&input) else { continue }
            keys.append(Self.string(fromFourCC: out.key))
        }
        return keys
    }

    private static func fourCC(_ s: String) -> UInt32 {
        let scalars = Array(s.utf8)
        guard scalars.count == 4 else { return 0 }
        return scalars.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func string(fromFourCC value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

// MARK: - IOReport power sampler

private final class IOReportPowerSampler {
    private var subscription: OpaquePointer?
    private var channels: CFMutableDictionary?
    private var lastSample: CFDictionary?
    private var lastSampleTime: TimeInterval = 0

    init?() {
        // "Energy Model" is the per-block energy counter group on M-series
        // (channels: "CPU Energy", "GPU Energy", "ANE Energy", ...).
        guard IOReport.isAvailable,
              let copyChannelsInGroup = IOReport.copyChannelsInGroup,
              let createSubscription = IOReport.createSubscription,
              let ch = copyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSubscription(nil, ch, &subscribed, 0, nil) else { return nil }
        subscription = sub
        channels = ch
    }

    /// Returns (cpuWatts, gpuWatts) averaged since the previous call, or nil
    /// on the first call / on failure.
    func sample() -> (cpu: Double?, gpu: Double?)? {
        guard let subscription, let channels,
              let createSamples = IOReport.createSamples,
              let createSamplesDelta = IOReport.createSamplesDelta,
              let iterate = IOReport.iterate,
              let channelGetChannelName = IOReport.channelGetChannelName,
              let channelGetUnitLabel = IOReport.channelGetUnitLabel,
              let simpleGetIntegerValue = IOReport.simpleGetIntegerValue,
              let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = Date().timeIntervalSinceReferenceDate
        defer { lastSample = current; lastSampleTime = now }
        guard let previous = lastSample, now > lastSampleTime else { return nil }

        let dt = now - lastSampleTime
        guard let delta = createSamplesDelta(previous, current, nil)?.takeRetainedValue() else { return nil }

        var cpuJoules = 0.0, gpuJoules = 0.0
        var foundCPU = false, foundGPU = false
        iterate(delta) { channel in
            guard let channel else { return 0 }
            let name = (channelGetChannelName(channel)?.takeUnretainedValue() as String?) ?? ""
            let unit = (channelGetUnitLabel(channel)?.takeUnretainedValue() as String?) ?? ""
            let raw = Double(simpleGetIntegerValue(channel, 0))
            guard let joules = EnergyUnitDecoder.joules(raw: raw, unit: unit) else { return 0 }
            if name.localizedCaseInsensitiveContains("CPU") {
                cpuJoules += joules
                foundCPU = true
            }
            if name.localizedCaseInsensitiveContains("GPU") {
                gpuJoules += joules
                foundGPU = true
            }
            return 0 // kIOReportIterOk
        }
        func watts(joules: Double, found: Bool) -> Double? {
            guard found else { return nil }
            let value = joules / dt
            return value.isFinite && value >= 0 && value <= 10_000 ? value : nil
        }
        return (watts(joules: cpuJoules, found: foundCPU),
                watts(joules: gpuJoules, found: foundGPU))
    }
}

// MARK: - SensorReader

/// Actor that owns all sensor handles and produces `SensorSnapshot`s.
/// Being an actor keeps the C calls off the main thread and serialized.
actor SensorReader {
    private var hidClient: OpaquePointer?
    private var smc: SMCConnection?
    private var power: IOReportPowerSampler?
    private var lastInitializationAttempt = Date.distantPast
    private static let initializationRetryInterval: TimeInterval = 30
    /// SMC temperature keys, enumerated once and reused each poll.
    private var smcTempKeys: [String]?
    /// Total number of SMC keys seen during enumeration (for diagnostics).
    private var smcAllKeyCount = 0

    private func initializeIfNeeded() {
        let now = Date()
        let hasMissingBackend = hidClient == nil || smc == nil || power == nil
        guard hasMissingBackend,
              now.timeIntervalSince(lastInitializationAttempt) >= Self.initializationRetryInterval else { return }
        lastInitializationAttempt = now

        // ⚠️ Returns a client whose service list is EMPTY when sandboxed.
        if hidClient == nil,
           let createClient = HID.createClient,
           let setMatching = HID.setMatching,
           let client = createClient(kCFAllocatorDefault) {
            hidClient = client
            let matching: [String: Int] = [
                "PrimaryUsagePage": kHIDPageAppleVendor,
                "PrimaryUsage": kHIDUsageAppleVendorTemperatureSensor,
            ]
            _ = setMatching(client, matching as CFDictionary)
        }
        if smc == nil, let connection = SMCConnection() {
            smc = connection
            smcTempKeys = nil
            smcAllKeyCount = 0
        }
        if power == nil {
            power = IOReportPowerSampler()
        }
    }

    func read() -> SensorSnapshot {
        initializeIfNeeded()

        let hidTemps = readTemperatures()
        let smcTemps = readSMCTemperatures()
        let temps = hidTemps + smcTemps
        let fanResult = readFans()
        let watts = power?.sample()

        let diagnostics = "HID \(hidTemps.count) · SMC \(smc == nil ? "closed" : "open")"
            + " · keys \(smcAllKeyCount) · T \(smcTempKeys?.count ?? 0) · vals \(smcTemps.count)"

        // Sensor browser shows only the human-readable HID sensors (PMU tdie,
        // NAND, battery…), collapsing duplicate instances (Apple exposes several
        // physical sensors under one name, e.g. "PMU tdie1" ×3) into one averaged
        // row. The cryptic SMC keys (Tp*/Ts*/Tg*) are excluded from the list but
        // still drive the CPU/GPU/SoC headline temps via `aggregate(temps, …)`.
        let dedupedSensors: [TempReading] = Dictionary(grouping: hidTemps, by: \.name)
            .map { name, items in
                TempReading(name: name, celsius: items.map(\.celsius).reduce(0, +) / Double(items.count))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return SensorSnapshot(
            date: .now,
            cpuTempC: aggregate(temps, matching: Self.isCPUSensor),
            gpuTempC: aggregate(temps, matching: Self.isGPUSensor),
            socTempC: aggregate(temps, matching: Self.isSoCSensor),
            cpuPowerW: watts?.cpu,
            gpuPowerW: watts?.gpu,
            fans: fanResult.fans,
            sensorCount: dedupedSensors.count,
            allSensors: dedupedSensors,
            thermalPressure: Self.thermalPressureString(),
            diagnostics: diagnostics,
            fanAvailability: fanResult.availability
        )
    }

    /// Public API — no IOKit needed. nominal/fair/serious/critical.
    private static func thermalPressureString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    // MARK: Temperatures (HID)

    private struct TempSensor { let name: String; let celsius: Double }

    private func readTemperatures() -> [TempSensor] {
        guard let hidClient,
              let copyServices = HID.copyServices,
              let copyProperty = HID.copyProperty,
              let copyEvent = HID.copyEvent,
              let getFloatValue = HID.getFloatValue,
              let services = copyServices(hidClient)?.takeRetainedValue() as? [AnyObject] else {
            return []
        }
        var sensors: [TempSensor] = []
        for object in services {
            let service = unsafeBitCast(object, to: OpaquePointer.self)
            let name = (copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String) ?? "Unknown"
            guard let eventRef = copyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let event = eventRef.takeRetainedValue()
            let value = getFloatValue(event, kIOHIDEventFieldTemperatureLevel)
            // Filter obviously bogus readings.
            if value > 0, value < 150 {
                sensors.append(TempSensor(name: name, celsius: value))
            }
        }
        return sensors
    }

    /// CPU/GPU/SoC die temps read from SMC. On Apple Silicon these live in SMC
    /// keys (Tp/Te = CPU perf/efficiency cores, Tg = GPU, Ts = SoC), NOT in the
    /// AppleVendor HID temperature sensors, which only expose peripherals
    /// (battery, NAND, PMU). That's why the HID-only path showed no core temps.
    private func readSMCTemperatures() -> [TempSensor] {
        guard let smc else { return [] }
        let keys: [String]
        if let cached = smcTempKeys {
            keys = cached
        } else {
            let all = smc.allKeys()
            smcAllKeyCount = all.count
            // Keep only the meaningful thermal families so the sensor browser
            // isn't flooded with hundreds of cryptic SMC keys:
            //   Tp/Te = CPU perf/efficiency cores, Tg = GPU, Ts = SoC,
            //   TC = CPU, TG = GPU, Tm = memory.
            let families = ["Tp", "Te", "Tg", "Ts", "TC", "TG", "Tm"]
            keys = all.filter { key in families.contains { key.hasPrefix($0) } }
            smcTempKeys = keys
        }
        var out: [TempSensor] = []
        for key in keys {
            guard let v = smc.readNumber(key), v > 0, v < 150 else { continue }
            out.append(TempSensor(name: key, celsius: v))
        }
        return out
    }

    /// Sensor-name classification for M-series HID temperature sensors.
    /// M1 family exposes verbose names ("pACC MTR Temp Sensor4", "eACC ...",
    /// "GPU MTR Temp Sensor1", "SOC MTR Temp Sensor2"); M2/M3/M4 expose
    /// short SMC-style names ("Tp01", "Tp09", "Tg0f", "Ts0a", ...).
    static func isCPUSensor(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("pacc") || lower.contains("eacc") || lower.contains("cpu")
            // Apple Silicon Max/Ultra expose per-die-cluster temps as "PMU tdieN"
            // (no CPU/GPU split in the name). The hottest die zone is the most
            // useful "how hot is the chip" number, so surface it as CPU.
            || lower.contains("tdie")
            || name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("TC")
    }
    static func isGPUSensor(_ name: String) -> Bool {
        // Note: on chips that only expose generic "PMU tdie" die zones, there is
        // no GPU-specific temperature sensor, so this row stays blank by design.
        name.lowercased().contains("gpu") || name.hasPrefix("Tg") || name.hasPrefix("TG")
    }
    static func isSoCSensor(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("soc") || lower.contains("tcal")
            || name.hasPrefix("Ts") || name.hasPrefix("Tm")
    }

    /// Hottest sensor in the category (what MacVitals-style tools display).
    private func aggregate(_ sensors: [TempSensor], matching predicate: (String) -> Bool) -> Double? {
        sensors.filter { predicate($0.name) }.map(\.celsius).max()
    }

    // MARK: Fans (SMC)

    private func readFans() -> (fans: [FanReading], availability: FanAvailability) {
        guard let smc, let reportedCount = smc.readNumber("FNum"),
              let count = Int(exactly: reportedCount),
              count >= 0, count <= 16 else { return ([], .unavailable) }
        guard count > 0 else { return ([], .noneReported) }
        var fans: [FanReading] = []
        for i in 0..<count {
            guard let rpm = validFanRPM(smc.readNumber("F\(i)Ac")) else { continue }
            fans.append(FanReading(
                id: i,
                name: fanName(index: i, total: count),
                rpm: rpm,
                minRPM: validFanRPM(smc.readNumber("F\(i)Mn")),
                maxRPM: validFanRPM(smc.readNumber("F\(i)Mx")),
                targetRPM: validFanRPM(smc.readNumber("F\(i)Tg"))
            ))
        }
        return (fans, fans.isEmpty ? .unavailable : .available)
    }

    private func validFanRPM(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 100_000 else { return nil }
        return value
    }

    private func fanName(index: Int, total: Int) -> String {
        // F%dID ('fds ' struct) rarely exists on Apple Silicon; use positional names.
        if total == 2 { return index == 0 ? "Left Fan" : "Right Fan" }
        return total == 1 ? "Fan" : "Fan \(index + 1)"
    }
}
