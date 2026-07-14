import SwiftUI
import Charts

private struct ModuleHeader: View {
    let title: String
    let systemImage: String
    let date: Date?

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage).font(.headline)
            Spacer()
            if let date {
                Text(date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    var systemImage: String? = nil
    var secondary = false

    var body: some View {
        HStack {
            if let systemImage { Label(title, systemImage: systemImage) }
            else { Text(title) }
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: secondary ? 11 : 13))
        .foregroundStyle(secondary ? .secondary : .primary)
    }
}

struct CPUMenuView: View {
    let model: SensorViewModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(title: "CPU", systemImage: "cpu", date: model.snapshot?.date)
            if let cpu = model.snapshot?.system?.cpu {
                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormat.percent(cpu.totalUsage))
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("total usage").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(value: cpu.totalUsage).controlSize(.small)
                cpuChart
                MetricRow(title: "User", value: MetricFormat.percent(cpu.userUsage), systemImage: "person")
                MetricRow(title: "System", value: MetricFormat.percent(cpu.systemUsage), systemImage: "gearshape")
                MetricRow(title: "Idle", value: MetricFormat.percent(cpu.idleUsage), systemImage: "moon")

                DisclosureGroup("Load & hardware", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 5) {
                        MetricRow(title: "Load average", value: loadAverage(cpu), secondary: true)
                        MetricRow(title: "Cores", value: "\(cpu.physicalCoreCount) physical / \(cpu.logicalCoreCount) logical", secondary: true)
                        MetricRow(
                            title: "Temperature",
                            value: TemperatureFormat.string(
                                model.snapshot?.cpuTempC,
                                fahrenheit: model.snapshot?.useFahrenheit ?? false
                            ),
                            secondary: true
                        )
                        MetricRow(title: "Power", value: model.snapshot?.cpuPowerW.map { String(format: "%.1f W", $0) } ?? "—", secondary: true)
                    }
                    .padding(.top, 5)
                }
                .font(.system(size: 12))
            } else {
                unavailable(model.history.count < 2
                    ? "Waiting for a second CPU sample…"
                    : "CPU statistics unavailable")
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var cpuChart: some View {
        Chart {
            ForEach(recentHistory, id: \.date) { snapshot in
                if let usage = snapshot.system?.cpu?.totalUsage {
                    LineMark(x: .value("Time", snapshot.date), y: .value("Usage", usage * 100))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
        .frame(height: 55)
        .accessibilityLabel("CPU usage history")
    }

    private var recentHistory: [SensorSnapshot] {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        return model.history.filter { $0.date >= cutoff }
    }

    private func loadAverage(_ cpu: CPUMetrics) -> String {
        [cpu.loadAverage1m, cpu.loadAverage5m, cpu.loadAverage15m]
            .map { $0.map { String(format: "%.2f", $0) } ?? "—" }
            .joined(separator: " / ")
    }
}

struct MemoryMenuView: View {
    let model: SensorViewModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(title: "Memory", systemImage: "memorychip", date: model.snapshot?.date)
            if let memory = model.snapshot?.system?.memory {
                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormat.percent(memory.usedFraction))
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("used").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    pressureLabel(memory.pressure)
                }
                ProgressView(value: memory.usedFraction ?? 0).controlSize(.small)
                memoryChart
                MetricRow(title: "Used", value: MetricFormat.bytes(memory.usedBytes), systemImage: "chart.pie.fill")
                MetricRow(title: "Available", value: MetricFormat.bytes(memory.availableBytes), systemImage: "circle.dotted")
                MetricRow(title: "Total", value: MetricFormat.bytes(memory.totalBytes), systemImage: "memorychip")

                DisclosureGroup("Memory breakdown", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 5) {
                        MetricRow(title: "Wired", value: MetricFormat.bytes(memory.wiredBytes), secondary: true)
                        MetricRow(title: "Compressed", value: MetricFormat.bytes(memory.compressedBytes), secondary: true)
                        MetricRow(title: "Cached files", value: MetricFormat.bytes(memory.cachedBytes), secondary: true)
                    }
                    .padding(.top, 5)
                }
                .font(.system(size: 12))
            } else {
                unavailable("Memory statistics unavailable")
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var memoryChart: some View {
        Chart {
            ForEach(recentHistory, id: \.date) { snapshot in
                if let usage = snapshot.system?.memory?.usedFraction {
                    LineMark(x: .value("Time", snapshot.date), y: .value("Used", usage * 100))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
        .frame(height: 55)
        .accessibilityLabel("Memory usage history")
    }

    private var recentHistory: [SensorSnapshot] {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        return model.history.filter { $0.date >= cutoff }
    }

    private func pressureLabel(_ pressure: MemoryPressureLevel) -> some View {
        Text(pressure.rawValue.capitalized)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(pressureColor(pressure).opacity(0.2), in: Capsule())
            .foregroundStyle(pressureColor(pressure))
    }

    private func pressureColor(_ pressure: MemoryPressureLevel) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct NetworkMenuView: View {
    let model: SensorViewModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(title: "Network", systemImage: "arrow.up.arrow.down", date: model.snapshot?.date)
            if let network = model.snapshot?.system?.network {
                MetricRow(title: "Download", value: MetricFormat.rate(network.downloadBytesPerSecond), systemImage: "arrow.down")
                MetricRow(title: "Upload", value: MetricFormat.rate(network.uploadBytesPerSecond), systemImage: "arrow.up")
                networkChart
                DisclosureGroup("Session & interface", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 5) {
                        MetricRow(title: "Interface", value: network.interfaceName, secondary: true)
                        MetricRow(title: "Downloaded", value: MetricFormat.bytes(network.sessionDownloadedBytes), secondary: true)
                        MetricRow(title: "Uploaded", value: MetricFormat.bytes(network.sessionUploadedBytes), secondary: true)
                    }
                    .padding(.top, 5)
                }
                .font(.system(size: 12))
            } else {
                unavailable("No active network interface")
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var networkChart: some View {
        Chart {
            ForEach(recentHistory, id: \.date) { snapshot in
                if let download = snapshot.system?.network?.downloadBytesPerSecond {
                    LineMark(
                        x: .value("Time", snapshot.date),
                        y: .value("Bytes per second", download),
                        series: .value("Direction", "Download")
                    )
                    .foregroundStyle(by: .value("Direction", "Download"))
                }
                if let upload = snapshot.system?.network?.uploadBytesPerSecond {
                    LineMark(
                        x: .value("Time", snapshot.date),
                        y: .value("Bytes per second", upload),
                        series: .value("Direction", "Upload")
                    )
                    .foregroundStyle(by: .value("Direction", "Upload"))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(position: .bottom, spacing: 2)
        .frame(height: 70)
        .accessibilityLabel("Network throughput history")
    }

    private var recentHistory: [SensorSnapshot] {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        return model.history.filter { $0.date >= cutoff }
    }
}

struct BatteryMenuView: View {
    let model: SensorViewModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(title: "Battery", systemImage: batterySymbol, date: model.snapshot?.date)
            if let battery = model.snapshot?.system?.battery {
                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormat.percent(battery.percentage))
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(battery.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(value: battery.percentage).controlSize(.small)
                MetricRow(title: "Power source", value: battery.isOnACPower ? "Power adapter" : "Battery", systemImage: "powerplug")
                MetricRow(title: battery.state == .charging ? "Until full" : "Remaining", value: MetricFormat.duration(battery.timeRemaining), systemImage: "clock")
                if battery.isLowPowerModeEnabled {
                    Label("Low Power Mode", systemImage: "leaf")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                DisclosureGroup("Battery details", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 5) {
                        MetricRow(title: "Condition", value: battery.health ?? "Unavailable", secondary: true)
                    }
                    .padding(.top, 5)
                }
                .font(.system(size: 12))
            } else {
                unavailable("No internal battery reported")
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var batterySymbol: String {
        guard let battery = model.snapshot?.system?.battery else { return "battery.0percent" }
        if battery.state == .charging { return "battery.100percent.bolt" }
        switch battery.percentage {
        case 0.75...: return "battery.100percent"
        case 0.5...: return "battery.75percent"
        case 0.25...: return "battery.50percent"
        default: return "battery.25percent"
        }
    }
}

struct DiskMenuView: View {
    let model: SensorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(title: "Disk", systemImage: "internaldrive", date: model.snapshot?.date)
            if let disk = model.snapshot?.system?.disk {
                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormat.percent(disk.usedFraction))
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("used on startup disk").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(value: disk.usedFraction ?? 0).controlSize(.small)
                MetricRow(title: "Used", value: MetricFormat.bytes(disk.usedBytes), systemImage: "internaldrive.fill")
                MetricRow(title: "Available", value: MetricFormat.bytes(disk.availableBytes), systemImage: "externaldrive.badge.checkmark")
                MetricRow(title: "Capacity", value: MetricFormat.bytes(disk.totalBytes), systemImage: "internaldrive")
            } else {
                unavailable("Startup disk capacity unavailable")
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}

private func unavailable(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .center)
}
