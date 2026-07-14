//
//  SharedStore.swift
//  Shared between the MacVitals app and the MacVitalsWidget extension.
//
//  The main (unsandboxed) app WRITES data into the App Group container;
//  the (sandboxed) widget READS it. This is the only data path the widget
//  has — widget extensions are always sandboxed and cannot talk to IOKit.
//

import Foundation
import Darwin

enum SharedStoreError: LocalizedError {
    case appGroupUnavailable
    case fileTooLarge(String)
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared App Group container is unavailable."
        case .fileTooLarge(let name):
            "\(name) exceeds MacVitals' safety limit."
        case .invalidFile(let name):
            "\(name) is not a regular file."
        }
    }
}

enum SharedStore {
    /// ⚠️ Keep in sync with both .entitlements files.
    static let appGroupID = "group.com.macvitals.shared"

    /// App-local settings store.
    ///
    /// These keys only drive the main (unsandboxed) app's own UI and logic.
    /// We deliberately do NOT use `UserDefaults(suiteName: appGroupID)` here:
    /// an unsandboxed process can't share a `group.` preferences domain with
    /// the sandboxed widget (cfprefsd logs "…only allowed for System
    /// Containers, detaching…" and the two processes read different plists).
    /// The one setting the widget needs (°C/°F) is stamped into the snapshot
    /// file instead — see `SensorSnapshot.useFahrenheit`. Optional type is
    /// kept so existing `?.` call sites compile unchanged.
    static let defaults: UserDefaults? = .standard

    // MARK: Settings keys (shared by app and widget)

    static let fahrenheitKey = "useFahrenheit"
    /// "temp" | "fan" | "both" — what the menu bar label shows.
    /// Poll interval in seconds (Double). Default 5.
    static let pollIntervalKey = "pollInterval"
    /// When true and on battery power, polling slows to ≥30 s.
    static let pauseOnBatteryKey = "pauseOnBattery"
    static let alertsEnabledKey = "alertsEnabled"
    /// CPU alert threshold in °C (Double). Default 90.
    static let alertThresholdKey = "alertThresholdC"
    static let csvLoggingKey = "csvLoggingEnabled"
    static let cpuModuleVisibleKey = "module.cpu.visible"
    static let memoryModuleVisibleKey = "module.memory.visible"
    static let networkModuleVisibleKey = "module.network.visible"
    static let batteryModuleVisibleKey = "module.battery.visible"
    static let diskModuleVisibleKey = "module.disk.visible"

    // MARK: Container paths

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    private static var snapshotURL: URL? { containerURL?.appendingPathComponent("snapshot.json") }
    private static var historyURL: URL? { containerURL?.appendingPathComponent("history.json") }
    private static let maxSnapshotBytes = 1_048_576
    private static let maxHistoryBytes = 4_194_304

    /// The CSV log lives in ~/Documents/MacVitals, NOT the App Group container.
    /// The main app is unsandboxed, so this path is directly user-accessible and
    /// can be revealed in Finder. Revealing a file inside the App Group container
    /// fails with a sandbox-extension error ("public.file-url … failed to obtain")
    /// because that container is a protected, sandbox-managed location.
    static var csvLogURL: URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MacVitals", isDirectory: true)
        return dir.appendingPathComponent("macvitals-log.csv")
    }

    // MARK: Latest snapshot

    static func save(_ snapshot: SensorSnapshot) throws {
        guard let url = snapshotURL else { throw SharedStoreError.appGroupUnavailable }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    static func load() -> SensorSnapshot? {
        guard let url = snapshotURL,
              let data = boundedData(at: url, maxBytes: maxSnapshotBytes),
              let snapshot = try? JSONDecoder().decode(SensorSnapshot.self, from: data),
              isValid(snapshot) else { return nil }
        return snapshot
    }

    // MARK: Rolling history (sparklines)

    static func appendHistory(_ point: HistoryPoint, cap: Int = 1_000) throws {
        let history = trimmedHistory(loadHistory(), adding: point, cap: cap)
        guard let url = historyURL else { throw SharedStoreError.appGroupUnavailable }
        let data = try JSONEncoder().encode(history)
        try data.write(to: url, options: .atomic)
    }

    static func loadHistory() -> [HistoryPoint] {
        guard let url = historyURL,
              let data = boundedData(at: url, maxBytes: maxHistoryBytes),
              let history = try? JSONDecoder().decode([HistoryPoint].self, from: data),
              history.count <= 1_000,
              history.allSatisfy(isValid) else { return [] }
        return history
    }

    // MARK: CSV logging

    static func appendCSV(_ snapshot: SensorSnapshot) throws {
        guard let url = csvLogURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let iso = ISO8601DateFormatter().string(from: snapshot.date)
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        let fanRPMs = snapshot.fans.map(\.displayRPM).joined(separator: "|")
        let line = [iso, fmt(snapshot.cpuTempC), fmt(snapshot.gpuTempC), fmt(snapshot.socTempC),
                    fmt(snapshot.cpuPowerW), fmt(snapshot.gpuPowerW), fanRPMs,
                    snapshot.thermalPressure ?? ""].joined(separator: ",") + "\n"
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw SharedStoreError.invalidFile(url.lastPathComponent)
        }

        let header = "timestamp,cpu_c,gpu_c,soc_c,cpu_w,gpu_w,fan_rpms,thermal_pressure\n"
        let payload = Data((metadata.st_size == 0 ? header + line : line).utf8)
        try writeAll(payload, to: descriptor)
    }

    // MARK: Validation and bounded reads

    private static func boundedData(at url: URL, maxBytes: Int) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maxBytes else { return nil }

        var data = Data(count: Int(metadata.st_size))
        let complete = data.withUnsafeMutableBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return rawBuffer.isEmpty }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.read(descriptor, cursor, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
            return true
        }
        return complete ? data : nil
    }

    static func isValid(_ snapshot: SensorSnapshot) -> Bool {
        let sensors = snapshot.allSensors ?? []
        return snapshot.date.timeIntervalSinceReferenceDate.isFinite
            && isValidTemperature(snapshot.cpuTempC)
            && isValidTemperature(snapshot.gpuTempC)
            && isValidTemperature(snapshot.socTempC)
            && isValidPower(snapshot.cpuPowerW)
            && isValidPower(snapshot.gpuPowerW)
            && snapshot.fans.count <= 16
            && snapshot.fans.allSatisfy { fan in
                fan.validRPM != nil
                    && isValidRPM(fan.minRPM)
                    && isValidRPM(fan.maxRPM)
                    && isValidRPM(fan.targetRPM)
            }
            && snapshot.sensorCount >= 0 && snapshot.sensorCount <= 4_096
            && sensors.count <= 4_096
            && sensors.allSatisfy { !$0.name.isEmpty && $0.name.count <= 256 && isValidTemperature($0.celsius) }
            && isValid(snapshot.system)
    }

    private static func isValid(_ point: HistoryPoint) -> Bool {
        point.date.timeIntervalSinceReferenceDate.isFinite
            && isValidTemperature(point.cpuTempC)
            && isValidTemperature(point.gpuTempC)
            && isValidRPM(point.maxFanRPM)
    }

    static func trimmedHistory(
        _ existing: [HistoryPoint],
        adding point: HistoryPoint,
        cap: Int = 1_000
    ) -> [HistoryPoint] {
        var history = existing
        history.append(point)
        let cutoff = point.date.addingTimeInterval(-30 * 60)
        history.removeAll { $0.date < cutoff }
        if history.count > cap { history.removeFirst(history.count - cap) }
        return history
    }

    private static func isValidTemperature(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value > 0 && value < 150
    }

    private static func isValidPower(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= 10_000
    }

    private static func isValidRPM(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= 100_000
    }

    private static func isValid(_ metrics: SystemMetrics?) -> Bool {
        guard let metrics else { return true }
        let cpuValid = metrics.cpu.map {
            [$0.totalUsage, $0.userUsage, $0.systemUsage, $0.idleUsage].allSatisfy {
                $0.isFinite && $0 >= 0 && $0 <= 1
            }
                && [$0.loadAverage1m, $0.loadAverage5m, $0.loadAverage15m].allSatisfy {
                    $0.map { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 } ?? true
                }
                && abs(($0.userUsage + $0.systemUsage) - $0.totalUsage) <= 0.000_001
                && abs(($0.totalUsage + $0.idleUsage) - 1) <= 0.000_001
                && $0.logicalCoreCount > 0 && $0.logicalCoreCount <= 1_024
                && $0.physicalCoreCount > 0 && $0.physicalCoreCount <= $0.logicalCoreCount
        } ?? true
        let memoryValid = metrics.memory.map {
            $0.totalBytes > 0
                && $0.usedBytes <= $0.totalBytes
                && $0.availableBytes <= $0.totalBytes
                && $0.usedBytes == $0.totalBytes - $0.availableBytes
                && $0.wiredBytes <= $0.totalBytes
                && $0.compressedBytes <= $0.totalBytes
                && $0.cachedBytes <= $0.totalBytes
        } ?? true
        let networkValid = metrics.network.map {
            !$0.interfaceName.isEmpty && $0.interfaceName.count <= 64
                && $0.interfaceName.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
                && isValidRate($0.downloadBytesPerSecond)
                && isValidRate($0.uploadBytesPerSecond)
        } ?? true
        let batteryValid = metrics.battery.map {
            $0.percentage.isFinite && $0.percentage >= 0 && $0.percentage <= 1
                && ($0.timeRemaining.map { $0.isFinite && $0 >= 0 && $0 <= 7 * 24 * 60 * 60 } ?? true)
                && ($0.health?.count ?? 0) <= 128
        } ?? true
        let diskValid = metrics.disk.map {
            $0.totalBytes > 0 && $0.availableBytes <= $0.totalBytes
        } ?? true
        return cpuValid && memoryValid && networkValid && batteryValid && diskValid
    }

    private static func isValidRate(_ value: Double?) -> Bool {
        guard let value else { return true }
        // 100 GB/s is deliberately generous while still rejecting corrupt data.
        return value.isFinite && value >= 0 && value <= 100_000_000_000
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
    }
}
