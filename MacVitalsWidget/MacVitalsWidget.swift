//
//  MacVitalsWidget.swift
//  MacVitalsWidget
//
//  Notification Center widget (WidgetKit; macOS 14+).
//
//  The widget is sandboxed (mandatory for extensions), so it CANNOT read
//  IOKit sensors itself. It displays the last SensorSnapshot — and now the
//  rolling temperature history — that the main app writes into the shared
//  App Group. WidgetKit budgets timeline reloads, so the widget stays
//  roughly minute-fresh while the app runs; the menu bar is the live view.
//

import WidgetKit
import SwiftUI
import Charts

struct MacVitalsEntry: TimelineEntry {
    let date: Date
    let snapshot: SensorSnapshot?
    let history: [HistoryPoint]
    let fahrenheit: Bool

    static var placeholder: MacVitalsEntry {
        let now = Date()
        return MacVitalsEntry(
            date: now,
            snapshot: SensorSnapshot(
                date: now,
                cpuTempC: 48, gpuTempC: 42, socTempC: 39,
                cpuPowerW: 3.2, gpuPowerW: 0.8,
                fans: [FanReading(id: 0, name: "Left Fan", rpm: 1780, minRPM: 1500, maxRPM: 5800, targetRPM: nil),
                       FanReading(id: 1, name: "Right Fan", rpm: 1820, minRPM: 1500, maxRPM: 5800, targetRPM: nil)],
                sensorCount: 24,
                allSensors: nil,
                thermalPressure: "Nominal",
                system: SystemMetrics(
                    cpu: CPUMetrics(totalUsage: 0.32, userUsage: 0.24, systemUsage: 0.08, idleUsage: 0.68,
                                    loadAverage1m: 1.1, loadAverage5m: 1.0, loadAverage15m: 0.9,
                                    logicalCoreCount: 10, physicalCoreCount: 10),
                    memory: MemoryMetrics(usedBytes: 12_000_000_000, availableBytes: 4_000_000_000,
                                          totalBytes: 16_000_000_000, wiredBytes: 2_000_000_000,
                                          compressedBytes: 1_000_000_000, cachedBytes: 3_000_000_000,
                                          pressure: .normal),
                    network: NetworkMetrics(interfaceName: "en0", downloadBytesPerSecond: 820_000,
                                            uploadBytesPerSecond: 95_000, sessionDownloadedBytes: 48_000_000,
                                            sessionUploadedBytes: 7_000_000),
                    battery: BatteryMetrics(percentage: 0.78, state: .discharging, isOnACPower: false,
                                            timeRemaining: 18_000, health: "Good", isLowPowerModeEnabled: false),
                    disk: DiskMetrics(totalBytes: 500_000_000_000, availableBytes: 180_000_000_000)
                )
            ),
            history: (0..<60).map {
                HistoryPoint(date: now.addingTimeInterval(Double($0 - 60) * 5),
                             cpuTempC: 45 + 6 * sin(Double($0) / 8),
                             gpuTempC: 40 + 4 * sin(Double($0) / 10),
                             maxFanRPM: 1800)
            },
            fahrenheit: false
        )
    }
}

struct MacVitalsProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacVitalsEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (MacVitalsEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacVitalsEntry>) -> Void) {
        let timeline = Timeline(entries: [currentEntry()],
                                policy: .after(.now.addingTimeInterval(60)))
        completion(timeline)
    }

    private func currentEntry() -> MacVitalsEntry {
        let snapshot = SharedStore.load()
        return MacVitalsEntry(
            date: .now,
            snapshot: snapshot,
            history: SharedStore.loadHistory(),
            fahrenheit: snapshot?.useFahrenheit ?? false
        )
    }
}

struct MacVitalsWidgetView: View {
    var entry: MacVitalsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "fanblades").font(.title2)
                    Text("Open MacVitals to start monitoring")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func content(_ snapshot: SensorSnapshot) -> some View {
        if family == .systemSmall {
            smallContent(snapshot)
        } else {
            mediumContent(snapshot)
        }
    }

    private func smallContent(_ snapshot: SensorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "fanblades")
                Text("MacVitals").font(.headline)
                Spacer()
            }
            row("CPU", TemperatureFormat.string(snapshot.cpuTempC, fahrenheit: entry.fahrenheit))
            row("Usage", MetricFormat.percent(snapshot.system?.cpu?.totalUsage))
            row("Memory", MetricFormat.percent(snapshot.system?.memory?.usedFraction))
            if let battery = snapshot.system?.battery {
                row("Battery", MetricFormat.percent(battery.percentage))
            }
            Spacer(minLength: 0)
        }
    }

    private func mediumContent(_ snapshot: SensorSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "fanblades")
                    Text("MacVitals").font(.headline)
                }
                row("CPU", TemperatureFormat.string(snapshot.cpuTempC, fahrenheit: entry.fahrenheit))
                row("GPU", TemperatureFormat.string(snapshot.gpuTempC, fahrenheit: entry.fahrenheit))
                row("SoC", TemperatureFormat.string(snapshot.socTempC, fahrenheit: entry.fahrenheit))
                ForEach(snapshot.fans) { fan in
                    row(fan.name, "\(fan.displayRPM) RPM")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.date, style: .time)
                    .font(.caption2).foregroundStyle(.secondary)
                row("CPU use", MetricFormat.percent(snapshot.system?.cpu?.totalUsage))
                row("Memory", MetricFormat.percent(snapshot.system?.memory?.usedFraction))
                row("Network ↓", MetricFormat.compactRate(snapshot.system?.network?.downloadBytesPerSecond))
                row("Network ↑", MetricFormat.compactRate(snapshot.system?.network?.uploadBytesPerSecond))
                if let battery = snapshot.system?.battery {
                    row("Battery", MetricFormat.percent(battery.percentage))
                }
                row("Disk", MetricFormat.percent(snapshot.system?.disk?.usedFraction))
                sparkline
                Text("CPU temp · \(historyMinutes) min")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 145)
        }
    }

    private var historyMinutes: Int {
        guard let first = entry.history.first?.date, let last = entry.history.last?.date else { return 0 }
        let minutes = last.timeIntervalSince(first) / 60
        guard minutes.isFinite else { return 0 }
        return Int(min(30, max(1, minutes)))
    }

    private var sparkline: some View {
        Chart {
            ForEach(entry.history) { point in
                if let cpu = point.cpuTempC {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Temp", TemperatureFormat.convert(cpu, fahrenheit: entry.fahrenheit))
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 34)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

struct MacVitalsWidget: Widget {
    let kind = "MacVitalsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacVitalsProvider()) { entry in
            MacVitalsWidgetView(entry: entry)
        }
        .configurationDisplayName("MacVitals")
        .description("Temperatures, fans, CPU, memory, network, battery, and disk at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
