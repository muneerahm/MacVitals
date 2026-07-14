import Foundation

enum MemoryPressureLevel: String, Codable, Hashable {
    case normal
    case warning
    case critical
}

struct CPUMetrics: Codable, Hashable {
    var totalUsage: Double
    var userUsage: Double
    var systemUsage: Double
    var idleUsage: Double
    var loadAverage1m: Double?
    var loadAverage5m: Double?
    var loadAverage15m: Double?
    var logicalCoreCount: Int
    var physicalCoreCount: Int
}

struct MemoryMetrics: Codable, Hashable {
    var usedBytes: UInt64
    var availableBytes: UInt64
    var totalBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedBytes: UInt64
    var pressure: MemoryPressureLevel

    var usedFraction: Double? {
        guard totalBytes > 0, usedBytes <= totalBytes else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }
}

struct NetworkMetrics: Codable, Hashable {
    var interfaceName: String
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
    var sessionDownloadedBytes: UInt64
    var sessionUploadedBytes: UInt64
}

enum BatteryState: String, Codable, Hashable {
    case charging
    case charged
    case discharging
    case connected
    case unknown
}

struct BatteryMetrics: Codable, Hashable {
    var percentage: Double
    var state: BatteryState
    var isOnACPower: Bool
    /// Remaining seconds until empty or full, when macOS provides an estimate.
    var timeRemaining: TimeInterval?
    var health: String?
    var isLowPowerModeEnabled: Bool
}

struct DiskMetrics: Codable, Hashable {
    var totalBytes: UInt64
    var availableBytes: UInt64

    var usedBytes: UInt64 { totalBytes >= availableBytes ? totalBytes - availableBytes : 0 }

    var usedFraction: Double? {
        guard totalBytes > 0, availableBytes <= totalBytes else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }
}

/// Public, low-overhead system statistics sampled by the main app. Every field
/// is optional so one unavailable subsystem never hides the others and older
/// thermal-only snapshots remain compatible.
struct SystemMetrics: Codable, Hashable {
    var cpu: CPUMetrics?
    var memory: MemoryMetrics?
    var network: NetworkMetrics?
    var battery: BatteryMetrics?
    var disk: DiskMetrics?
}

enum MetricFormat {
    static func percent(_ fraction: Double?, decimals: Int = 0) -> String {
        guard let fraction, fraction.isFinite, fraction >= 0 else { return "—" }
        return String(format: "%.*f%%", decimals, min(fraction, 1) * 100)
    }

    static func bytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return "—" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var scaled = value
        var index = 0
        while scaled >= 1_000, index < units.count - 1 {
            scaled /= 1_000
            index += 1
        }
        let decimals = scaled >= 100 || index == 0 ? 0 : 1
        return String(format: "%.*f %@", decimals, scaled, units[index])
    }

    /// Short status-item rate with a stable, narrow width.
    static func compactRate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return "—" }
        if value < 1_000 { return String(format: "%.0fB", value) }
        if value < 1_000_000 { return String(format: "%.0fK", value / 1_000) }
        if value < 1_000_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        return String(format: "%.1fG", value / 1_000_000_000)
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0,
              seconds <= Double(Int.max) else { return "—" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
