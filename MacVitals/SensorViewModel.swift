//
//  SensorViewModel.swift
//  MacVitals
//

import Foundation
import Observation
import WidgetKit
import UserNotifications
import IOKit.ps

@MainActor
@Observable
final class SensorViewModel {
    private(set) var snapshot: SensorSnapshot?
    /// In-memory history for the dropdown chart (last 30 minutes).
    private(set) var history: [SensorSnapshot] = []
    private(set) var statusMessage: String?
    private(set) var persistenceMessage: String?
    private(set) var alertMessage: String?
    private(set) var onBattery = false

    @ObservationIgnored private let reader = SensorReader()
    @ObservationIgnored private let systemReader = SystemReader()
    @ObservationIgnored private let persistence = SnapshotPersistence()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPersistence: PersistenceRequest?
    @ObservationIgnored private var lastWidgetReloadDate = Date.distantPast
    @ObservationIgnored private var lastAlertDate: Date?
    @ObservationIgnored private var wasAboveThreshold = false
    @ObservationIgnored var snapshotDidChange: ((SensorSnapshot) -> Void)?

    private static let historyWindow: TimeInterval = 30 * 60
    private static let historyCap = 1_000
    private static let widgetReloadInterval: TimeInterval = 60
    /// Minimum gap between overheat notifications.
    private static let alertCooldown: TimeInterval = 600

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [reader, systemReader] in
            while !Task.isCancelled {
                async let sensorSample = reader.read()
                async let systemSample = systemReader.read()
                var snap = await sensorSample
                snap.system = await systemSample
                guard !Task.isCancelled else { return }
                self.ingest(snap)
                try? await Task.sleep(for: .seconds(self.effectiveInterval()))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Per-sample pipeline

    private func ingest(_ snap: SensorSnapshot) {
        var snap = snap
        // Stamp the shared °C/°F preference into the snapshot so the widget
        // reads it from the (reliable) container file, not a UserDefaults suite.
        snap.useFahrenheit = SharedStore.defaults?.bool(forKey: SharedStore.fahrenheitKey) ?? false
        snapshot = snap
        snapshotDidChange?(snap)
        history.append(snap)
        let historyCutoff = snap.date.addingTimeInterval(-Self.historyWindow)
        history.removeAll { $0.date < historyCutoff }
        if history.count > Self.historyCap { history.removeFirst(history.count - Self.historyCap) }
        if snap.hasAnyData {
            statusMessage = nil
        } else {
            let detail = snap.diagnostics.map { " (\($0))" } ?? ""
            statusMessage = "No temperature sensors matched. If the app is sandboxed, IOKit is blocked — see README.\(detail)"
        }
        onBattery = snap.system?.battery.map { !$0.isOnACPower } ?? Self.isOnBattery()

        let historyPoint = HistoryPoint(
            date: snap.date,
            cpuTempC: snap.cpuTempC,
            gpuTempC: snap.gpuTempC,
            maxFanRPM: snap.fans.compactMap(\.validRPM).max()
        )
        let csvEnabled = SharedStore.defaults?.bool(forKey: SharedStore.csvLoggingKey) == true
        let shouldReloadWidget = snap.date.timeIntervalSince(lastWidgetReloadDate) >= Self.widgetReloadInterval
        if shouldReloadWidget { lastWidgetReloadDate = snap.date }
        let pending = pendingPersistence
        pendingPersistence = PersistenceRequest(
            snapshot: snap,
            historyPoint: historyPoint,
            // The newest preference wins: disabling CSV must not allow a later,
            // coalesced snapshot to be written under an older pending opt-in.
            csvEnabled: csvEnabled,
            reloadWidget: shouldReloadWidget || (pending?.reloadWidget ?? false)
        )
        if persistenceTask == nil {
            persistenceTask = Task { await self.drainPersistence() }
        }
        checkAlert(snap)

    }

    private func drainPersistence() async {
        while !Task.isCancelled, let request = pendingPersistence {
            pendingPersistence = nil
            let result = await persistence.persist(
                snapshot: request.snapshot,
                historyPoint: request.historyPoint,
                csvEnabled: request.csvEnabled
            )
            persistenceMessage = result.message
            if request.reloadWidget, result.snapshotSaved {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        persistenceTask = nil
    }

    // MARK: Adaptive polling

    private func effectiveInterval() -> Double {
        let defaults = SharedStore.defaults
        var interval = Self.normalizedPollInterval(
            defaults?.double(forKey: SharedStore.pollIntervalKey) ?? 5
        )
        if defaults?.bool(forKey: SharedStore.pauseOnBatteryKey) == true, onBattery {
            interval = max(interval, 30)
        }
        return interval
    }

    static func normalizedPollInterval(_ value: Double) -> Double {
        value.isFinite && (1...3_600).contains(value) ? value : 5
    }

    private static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? else {
            return false
        }
        return type == kIOPMBatteryPowerKey
    }

    // MARK: Overheat notifications

    private func checkAlert(_ snap: SensorSnapshot) {
        let defaults = SharedStore.defaults
        guard defaults?.bool(forKey: SharedStore.alertsEnabledKey) == true,
              let cpu = snap.cpuTempC else { return }
        var threshold = defaults?.double(forKey: SharedStore.alertThresholdKey) ?? 90
        if threshold < 40 { threshold = 90 }

        let above = cpu >= threshold
        defer { wasAboveThreshold = above }
        // Only fire on the upward crossing, with a cooldown.
        guard above, !wasAboveThreshold else { return }
        if let last = lastAlertDate, Date().timeIntervalSince(last) < Self.alertCooldown { return }
        let content = UNMutableNotificationContent()
        content.title = "MacVitals — CPU running hot"
        content.body = String(format: "CPU reached %.0f °C (alert threshold %.0f °C).", cpu, threshold)
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                lastAlertDate = Date()
                alertMessage = nil
            } catch {
                alertMessage = "Overheat alert could not be delivered: \(error.localizedDescription)"
            }
        }
    }

    static func requestNotificationPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }
}

private struct PersistenceRequest {
    let snapshot: SensorSnapshot
    let historyPoint: HistoryPoint
    let csvEnabled: Bool
    let reloadWidget: Bool
}

private actor SnapshotPersistence {
    struct Result {
        let snapshotSaved: Bool
        let message: String?
    }

    func persist(
        snapshot: SensorSnapshot,
        historyPoint: HistoryPoint,
        csvEnabled: Bool
    ) -> Result {
        var messages: [String] = []
        let snapshotSaved: Bool
        do {
            try SharedStore.save(snapshot)
            snapshotSaved = true
        } catch {
            snapshotSaved = false
            messages.append("Widget snapshot could not be saved: \(error.localizedDescription)")
        }

        do {
            try SharedStore.appendHistory(historyPoint)
        } catch where snapshotSaved {
            messages.append("Widget history could not be saved: \(error.localizedDescription)")
        } catch {
            // The snapshot message already explains the shared-container failure.
        }

        if csvEnabled {
            do {
                try SharedStore.appendCSV(snapshot)
            } catch {
                messages.append("CSV logging failed: \(error.localizedDescription)")
            }
        }

        return Result(snapshotSaved: snapshotSaved, message: messages.first)
    }
}
