//
//  SensorSnapshot.swift
//  Shared between the MacVitals app and the MacVitalsWidget extension.
//

import Foundation

struct FanReading: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var rpm: Double
    var minRPM: Double?
    var maxRPM: Double?
    var targetRPM: Double?

    /// A bounded value safe to convert to an integer for UI and CSV output.
    var validRPM: Double? {
        guard rpm.isFinite, rpm >= 0, rpm <= 100_000 else { return nil }
        return rpm
    }

    var displayRPM: String {
        validRPM.map { String(Int($0.rounded())) } ?? "—"
    }

    /// 0...1 position between min and max RPM, if both are known.
    var normalized: Double? {
        guard let rpm = validRPM,
              let minRPM, minRPM.isFinite,
              let maxRPM, maxRPM.isFinite,
              maxRPM > minRPM else { return nil }
        return max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM)))
    }
}

/// A single raw HID temperature sensor reading (for the sensor browser).
struct TempReading: Codable, Identifiable, Hashable {
    var name: String
    var celsius: Double
    var id: String { name }
}

enum FanAvailability: String, Codable, Hashable {
    case available
    case noneReported
    case unavailable
}

/// One point of rolling history persisted to the App Group (for sparklines
/// in both the dropdown and the widget).
struct HistoryPoint: Codable, Hashable, Identifiable {
    var date: Date
    var cpuTempC: Double?
    var gpuTempC: Double?
    var maxFanRPM: Double?
    var id: Date { date }
}

struct SensorSnapshot: Codable, Hashable {
    var date: Date
    var cpuTempC: Double?
    var gpuTempC: Double?
    var socTempC: Double?
    var cpuPowerW: Double?
    var gpuPowerW: Double?
    var fans: [FanReading]
    var sensorCount: Int
    /// Every raw HID temperature sensor, sorted by name. Optional so old
    /// persisted snapshots still decode.
    var allSensors: [TempReading]?
    /// ProcessInfo.thermalState: "Nominal" / "Fair" / "Serious" / "Critical".
    var thermalPressure: String?
    /// The user's °C/°F choice, stamped in by the app so the sandboxed widget
    /// can honor it without sharing a UserDefaults suite. Optional so older
    /// persisted snapshots still decode.
    var useFahrenheit: Bool?
    /// Short debug string describing what the reader saw (HID/SMC counts).
    /// Surfaced in the status banner only when no core temps were found.
    var diagnostics: String?
    /// Distinguishes a fanless machine from an inaccessible or unreadable SMC.
    var fanAvailability: FanAvailability? = nil
    /// Public system statistics for the app's independent CPU, memory, network,
    /// battery, and disk menu-bar modules. Optional for thermal-only snapshots
    /// written by older MacVitals versions.
    var system: SystemMetrics? = nil

    var hasAnyData: Bool {
        cpuTempC != nil || gpuTempC != nil || socTempC != nil || !fans.isEmpty
    }
}

enum TemperatureFormat {
    /// °C → display string, honoring the shared °C/°F preference.
    static func string(_ celsius: Double?, fahrenheit: Bool) -> String {
        guard let celsius else { return "—" }
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: "%.0f°%@", value, fahrenheit ? "F" : "C")
    }

    static func convert(_ celsius: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }
}
