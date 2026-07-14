import Foundation
import Darwin
import Dispatch
import IOKit
import IOKit.ps
import SystemConfiguration

struct CPUTickSample: Equatable {
    var user: UInt64
    var system: UInt64
    var nice: UInt64
    var idle: UInt64
}

struct NetworkCounterSample: Equatable {
    var interfaceName: String
    var receivedBytes: UInt64
    var sentBytes: UInt64
}

enum SystemMetricMath {
    static func cpu(current: CPUTickSample, previous: CPUTickSample) -> (total: Double, user: Double, system: Double, idle: Double)? {
        guard current.user >= previous.user,
              current.system >= previous.system,
              current.nice >= previous.nice,
              current.idle >= previous.idle else { return nil }

        let user = current.user - previous.user
        let system = current.system - previous.system
        let nice = current.nice - previous.nice
        let idle = current.idle - previous.idle
        let total = user + system + nice + idle
        guard total > 0 else { return nil }
        let divisor = Double(total)
        let userFraction = Double(user + nice) / divisor
        let systemFraction = Double(system) / divisor
        let idleFraction = Double(idle) / divisor
        return (min(1, userFraction + systemFraction), userFraction, systemFraction, idleFraction)
    }

    static func network(
        current: NetworkCounterSample,
        previous: NetworkCounterSample,
        elapsed: TimeInterval
    ) -> (download: Double, upload: Double, downloaded: UInt64, uploaded: UInt64)? {
        guard elapsed.isFinite, elapsed > 0,
              elapsed <= 120,
              current.interfaceName == previous.interfaceName,
              current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes else { return nil }
        let downloaded = current.receivedBytes - previous.receivedBytes
        let uploaded = current.sentBytes - previous.sentBytes
        return (Double(downloaded) / elapsed, Double(uploaded) / elapsed, downloaded, uploaded)
    }

    static func pageBytes(_ pages: UInt64, pageSize: UInt64) -> UInt64? {
        let result = pages.multipliedReportingOverflow(by: pageSize)
        return result.overflow ? nil : result.partialValue
    }

    /// Approximates Activity Monitor's Memory Used accounting. Anonymous
    /// purgeable pages and file-backed pages are reclaimable cache, so they must
    /// not be counted as occupied merely because they sit on active/inactive VM
    /// queues.
    static func memory(
        totalBytes: UInt64,
        pageSize: UInt64,
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        externalPages: UInt64
    ) -> (used: UInt64, available: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64)? {
        guard totalBytes > 0, pageSize > 0, internalPages >= purgeablePages,
              let anonymous = pageBytes(internalPages - purgeablePages, pageSize: pageSize),
              let wired = pageBytes(wiredPages, pageSize: pageSize),
              let compressed = pageBytes(compressorPages, pageSize: pageSize),
              let fileBacked = pageBytes(externalPages, pageSize: pageSize),
              let purgeable = pageBytes(purgeablePages, pageSize: pageSize) else { return nil }

        let anonymousAndWired = anonymous.addingReportingOverflow(wired)
        guard !anonymousAndWired.overflow else { return nil }
        let occupied = anonymousAndWired.partialValue.addingReportingOverflow(compressed)
        guard !occupied.overflow, occupied.partialValue <= totalBytes else { return nil }

        let available = totalBytes - occupied.partialValue
        let reclaimable = fileBacked.addingReportingOverflow(purgeable)
        guard !reclaimable.overflow else { return nil }
        return (
            occupied.partialValue,
            available,
            wired,
            compressed,
            min(available, reclaimable.partialValue)
        )
    }

    static func disk(total: Int64?, available: Int64?) -> DiskMetrics? {
        guard let total, let available, total > 0, available >= 0, available <= total else { return nil }
        return DiskMetrics(totalBytes: UInt64(total), availableBytes: UInt64(available))
    }
}

/// Reads public system statistics without creating network connections, helper
/// processes, or additional timers. CPU/memory/network share the existing MacVitals
/// poll loop; battery and disk values are cached because they change slowly.
actor SystemReader {
    private struct TimedNetworkSample {
        var counters: NetworkCounterSample
        var instant: ContinuousClock.Instant
    }

    private let clock = ContinuousClock()
    private let pressureMonitor = MemoryPressureMonitor()
    private var previousCPU: CPUTickSample?
    private var previousNetwork: TimedNetworkSample?
    private var sessionDownloaded: UInt64 = 0
    private var sessionUploaded: UInt64 = 0
    private var cachedBattery: BatteryMetrics?
    private var batteryRefresh: ContinuousClock.Instant?
    private var cachedDisk: DiskMetrics?
    private var diskRefresh: ContinuousClock.Instant?

    private static let batteryRefreshInterval: TimeInterval = 30
    private static let diskRefreshInterval: TimeInterval = 60

    func read() -> SystemMetrics {
        let now = clock.now
        let cpu = readCPU()
        let memory = readMemory()
        let network = readNetwork(at: now)

        if batteryRefresh.map({ elapsed(from: $0, to: now) >= Self.batteryRefreshInterval }) != false {
            cachedBattery = readBattery()
            batteryRefresh = now
        }
        if diskRefresh.map({ elapsed(from: $0, to: now) >= Self.diskRefreshInterval }) != false {
            cachedDisk = readDisk()
            diskRefresh = now
        }

        return SystemMetrics(
            cpu: cpu,
            memory: memory,
            network: network,
            battery: cachedBattery,
            disk: cachedDisk
        )
    }

    private func readCPU() -> CPUMetrics? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let current = CPUTickSample(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3),
            idle: UInt64(info.cpu_ticks.2)
        )
        defer { previousCPU = current }
        guard let previousCPU,
              let usage = SystemMetricMath.cpu(current: current, previous: previousCPU) else { return nil }

        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, Int32(loads.count))
        return CPUMetrics(
            totalUsage: usage.total,
            userUsage: usage.user,
            systemUsage: usage.system,
            idleUsage: usage.idle,
            loadAverage1m: loadCount > 0 ? loads[0] : nil,
            loadAverage5m: loadCount > 1 ? loads[1] : nil,
            loadAverage15m: loadCount > 2 ? loads[2] : nil,
            logicalCoreCount: ProcessInfo.processInfo.processorCount,
            physicalCoreCount: physicalCoreCount()
        )
    }

    private func physicalCoreCount() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.physicalcpu", &value, &size, nil, 0) == 0, value > 0 else {
            return ProcessInfo.processInfo.processorCount
        }
        return Int(value)
    }

    private func readMemory() -> MemoryMetrics? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSizeValue: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSizeValue) == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(pageSizeValue)
        let total = ProcessInfo.processInfo.physicalMemory
        guard let values = SystemMetricMath.memory(
            totalBytes: total,
            pageSize: pageSize,
            internalPages: UInt64(statistics.internal_page_count),
            purgeablePages: UInt64(statistics.purgeable_count),
            wiredPages: UInt64(statistics.wire_count),
            compressorPages: UInt64(statistics.compressor_page_count),
            externalPages: UInt64(statistics.external_page_count)
        ) else { return nil }

        return MemoryMetrics(
            usedBytes: values.used,
            availableBytes: values.available,
            totalBytes: total,
            wiredBytes: values.wired,
            compressedBytes: values.compressed,
            cachedBytes: values.cached,
            pressure: pressureMonitor.current
        )
    }

    private func readNetwork(at now: ContinuousClock.Instant) -> NetworkMetrics? {
        guard let current = readNetworkCounters() else {
            previousNetwork = nil
            return nil
        }
        defer { previousNetwork = TimedNetworkSample(counters: current, instant: now) }

        var downloadRate: Double?
        var uploadRate: Double?
        if let previousNetwork,
           let rate = SystemMetricMath.network(
               current: current,
               previous: previousNetwork.counters,
               elapsed: elapsed(from: previousNetwork.instant, to: now)
           ) {
            downloadRate = rate.download
            uploadRate = rate.upload
            sessionDownloaded = addingClamped(sessionDownloaded, rate.downloaded)
            sessionUploaded = addingClamped(sessionUploaded, rate.uploaded)
        }
        return NetworkMetrics(
            interfaceName: current.interfaceName,
            downloadBytesPerSecond: downloadRate,
            uploadBytesPerSecond: uploadRate,
            sessionDownloadedBytes: sessionDownloaded,
            sessionUploadedBytes: sessionUploaded
        )
    }

    private func readNetworkCounters() -> NetworkCounterSample? {
        guard let primary = primaryInterfaceName() else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let raw = current.pointee.ifa_data else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            let sample = NetworkCounterSample(
                interfaceName: name,
                receivedBytes: UInt64(data.ifi_ibytes),
                sentBytes: UInt64(data.ifi_obytes)
            )
            if name == primary { return sample }
        }
        return nil
    }

    private func primaryInterfaceName() -> String? {
        for family in ["IPv4", "IPv6"] {
            guard let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString),
                  let dictionary = value as? [String: Any],
                  let interface = dictionary["PrimaryInterface"] as? String else { continue }
            return interface
        }
        return nil
    }

    private func readBattery() -> BatteryMetrics? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sourceList {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType else { continue }

            let current = number(description, key: kIOPSCurrentCapacityKey as String)
            let maximum = number(description, key: kIOPSMaxCapacityKey as String)
            guard let current, let maximum, maximum > 0 else { continue }
            let percentage = max(0, min(1, current / maximum))
            let isCharging = description[kIOPSIsChargingKey as String] as? Bool == true
            let isCharged = description[kIOPSIsChargedKey as String] as? Bool == true
            let sourceState = description[kIOPSPowerSourceStateKey as String] as? String
            let isOnAC = sourceState == kIOPSACPowerValue
            let state: BatteryState = isCharged ? .charged : isCharging ? .charging : isOnAC ? .connected : .discharging
            let timeKey = isCharging ? kIOPSTimeToFullChargeKey as String : kIOPSTimeToEmptyKey as String
            let minutes = number(description, key: timeKey)
            let remaining = minutes.flatMap {
                $0 >= 0 && $0 <= 7 * 24 * 60 && $0.isFinite ? $0 * 60 : nil
            }
            let health = description[kIOPSBatteryHealthKey as String] as? String
            return BatteryMetrics(
                percentage: percentage,
                state: state,
                isOnACPower: isOnAC,
                timeRemaining: remaining,
                health: health,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
        return nil
    }

    private func number(_ dictionary: [String: Any], key: String) -> Double? {
        guard let number = dictionary[key] as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func readDisk() -> DiskMetrics? {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        guard let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return nil }
        return SystemMetricMath.disk(
            total: values.volumeTotalCapacity.map(Int64.init),
            available: values.volumeAvailableCapacityForImportantUsage
        )
    }

    private func elapsed(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: end).components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func addingClamped(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

private final class MemoryPressureMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var level: MemoryPressureLevel = .normal
    private var source: (any DispatchSourceMemoryPressure)?

    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .global(qos: .utility))
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self, let data = self.source?.data else { return }
            let next: MemoryPressureLevel
            if data.contains(.critical) { next = .critical }
            else if data.contains(.warning) { next = .warning }
            else { next = .normal }
            self.lock.lock()
            self.level = next
            self.lock.unlock()
        }
        source.activate()
    }

    deinit { source?.cancel() }

    var current: MemoryPressureLevel {
        lock.lock()
        defer { lock.unlock() }
        return level
    }
}
