//
//  MenuBarView.swift
//  MacVitals
//
//  The dropdown shown when clicking the menu bar item.
//

import SwiftUI
import AppKit
import Charts
import ServiceManagement

struct MenuBarView: View {
    let model: SensorViewModel

    @AppStorage(SharedStore.fahrenheitKey, store: SharedStore.defaults)
    private var useFahrenheit = false
    @AppStorage(SharedStore.pollIntervalKey, store: SharedStore.defaults)
    private var pollInterval = 5.0
    @AppStorage(SharedStore.pauseOnBatteryKey, store: SharedStore.defaults)
    private var pauseOnBattery = false
    @AppStorage(SharedStore.alertsEnabledKey, store: SharedStore.defaults)
    private var alertsEnabled = false
    @AppStorage(SharedStore.alertThresholdKey, store: SharedStore.defaults)
    private var alertThresholdC = 90.0
    @AppStorage(SharedStore.csvLoggingKey, store: SharedStore.defaults)
    private var csvLogging = false
    @AppStorage(SharedStore.cpuModuleVisibleKey, store: SharedStore.defaults)
    private var cpuModuleVisible = true
    @AppStorage(SharedStore.memoryModuleVisibleKey, store: SharedStore.defaults)
    private var memoryModuleVisible = false
    @AppStorage(SharedStore.networkModuleVisibleKey, store: SharedStore.defaults)
    private var networkModuleVisible = false
    @AppStorage(SharedStore.batteryModuleVisibleKey, store: SharedStore.defaults)
    private var batteryModuleVisible = false
    @AppStorage(SharedStore.diskModuleVisibleKey, store: SharedStore.defaults)
    private var diskModuleVisible = false

    @State private var showSensors = false
    @State private var showSettings = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var settingsMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let snapshot = model.snapshot {
                temperatureSection(snapshot)
                if model.history.count > 2 { historyChart }
                Divider()
                fanSection(snapshot)
                if snapshot.cpuPowerW != nil || snapshot.gpuPowerW != nil {
                    Divider()
                    powerSection(snapshot)
                }
                Divider()
                sensorBrowser(snapshot)
                settingsSection
            } else {
                ProgressView("Reading sensors…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let persistence = model.persistenceMessage {
                Text(persistence).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let alert = model.alertMessage {
                Text(alert).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let settingsMessage {
                Text(settingsMessage).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            menuBarModulesSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Label("MacVitals", systemImage: "fanblades").font(.headline)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let date = model.snapshot?.date {
                    Text(date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Last updated \(date.formatted(date: .omitted, time: .shortened))")
                }
                if let pressure = model.snapshot?.thermalPressure, pressure != "Nominal" {
                    Text(pressure)
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(pressureColor(pressure).opacity(0.2), in: Capsule())
                        .foregroundStyle(pressureColor(pressure))
                }
                if model.onBattery && pauseOnBattery {
                    Text("battery — slow polling").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pressureColor(_ pressure: String) -> Color {
        switch pressure {
        case "Fair": .yellow
        case "Serious": .orange
        case "Critical": .red
        default: .secondary
        }
    }

    // MARK: Temperatures

    private func temperatureSection(_ snapshot: SensorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            tempRow(label: "CPU", systemImage: "cpu", celsius: snapshot.cpuTempC)
            tempRow(label: "GPU", systemImage: "cpu.fill", celsius: snapshot.gpuTempC)
            tempRow(label: "SoC / Other", systemImage: "memorychip", celsius: snapshot.socTempC)
        }
    }

    private func tempRow(label: String, systemImage: String, celsius: Double?) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
            Spacer()
            Text(TemperatureFormat.string(celsius, fahrenheit: useFahrenheit))
                .monospacedDigit()
                .foregroundStyle(color(for: celsius))
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }

    private func color(for celsius: Double?) -> Color {
        guard let celsius else { return .secondary }
        switch celsius {
        case ..<60: return .primary
        case ..<85: return .orange
        default: return .red
        }
    }

    // MARK: History chart

    private var historyChart: some View {
        Chart {
            ForEach(model.history, id: \.date) { snap in
                if let cpu = snap.cpuTempC {
                    LineMark(
                        x: .value("Time", snap.date),
                        y: .value("Temp", TemperatureFormat.convert(cpu, fahrenheit: useFahrenheit)),
                        series: .value("Series", "CPU")
                    )
                    .foregroundStyle(by: .value("Series", "CPU"))
                }
                if let gpu = snap.gpuTempC {
                    LineMark(
                        x: .value("Time", snap.date),
                        y: .value("Temp", TemperatureFormat.convert(gpu, fahrenheit: useFahrenheit)),
                        series: .value("Series", "GPU")
                    )
                    .foregroundStyle(by: .value("Series", "GPU"))
                }
            }
        }
        .chartForegroundStyleScale(["CPU": Color.red, "GPU": Color.blue])
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis(.hidden)
        .chartLegend(position: .bottom, spacing: 2)
        .frame(height: 70)
        .accessibilityLabel("Temperature history")
        .accessibilityValue(temperatureHistorySummary)
    }

    // MARK: Fans

    @ViewBuilder
    private func fanSection(_ snapshot: SensorSnapshot) -> some View {
        if snapshot.fans.isEmpty {
            Label(
                snapshot.fanAvailability == .noneReported
                    ? "No fans reported (fanless Mac)"
                    : "Fan RPM unavailable (SMC not accessible)",
                systemImage: "wind"
            )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.fans) { fan in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Label(fan.name, systemImage: "fanblades")
                            Spacer()
                            Text("\(fan.displayRPM) RPM").monospacedDigit()
                        }
                        .font(.system(size: 13))
                        if let normalized = fan.normalized {
                            ProgressView(value: normalized)
                                .controlSize(.small)
                                .accessibilityLabel("\(fan.name) speed range")
                                .accessibilityValue("\(Int((normalized * 100).rounded())) percent")
                        }
                    }
                }
            }
        }
    }

    // MARK: Power

    private func powerSection(_ snapshot: SensorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cpu = snapshot.cpuPowerW {
                HStack {
                    Label("CPU Power", systemImage: "bolt")
                    Spacer()
                    Text(String(format: "%.1f W", cpu)).monospacedDigit()
                }
            }
            if let gpu = snapshot.gpuPowerW {
                HStack {
                    Label("GPU Power", systemImage: "bolt.fill")
                    Spacer()
                    Text(String(format: "%.1f W", gpu)).monospacedDigit()
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    // MARK: Sensor browser

    @ViewBuilder
    private func sensorBrowser(_ snapshot: SensorSnapshot) -> some View {
        let sensors = snapshot.allSensors ?? []
        DisclosureGroup(isExpanded: $showSensors) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(sensors.enumerated()), id: \.offset) { _, sensor in
                        HStack {
                            Text(sensor.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(TemperatureFormat.string(sensor.celsius, fahrenheit: useFahrenheit))
                                .monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 140)
        } label: {
            Text("All sensors (\(sensors.count))").font(.system(size: 12))
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 8) {
                Text("General")
                    .font(.caption)
                    .fontWeight(.medium)

                Picker("Refresh every", selection: $pollInterval) {
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                    Text("30 s").tag(30.0)
                }

                Toggle("Slow down on battery", isOn: $pauseOnBattery)
                Toggle("Use Fahrenheit", isOn: $useFahrenheit)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            settingsMessage = nil
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            settingsMessage = "Launch at login could not be changed: \(error.localizedDescription)"
                        }
                    }

                Divider()

                Text("Alerts & logging")
                    .font(.caption)
                    .fontWeight(.medium)

                Toggle("Alert when CPU is hot", isOn: $alertsEnabled)
                    .onChange(of: alertsEnabled) { _, on in
                        guard on else { return }
                        Task {
                            let granted = await SensorViewModel.requestNotificationPermission()
                            if granted {
                                settingsMessage = nil
                            } else {
                                alertsEnabled = false
                                settingsMessage = "Notifications are not allowed. Enable MacVitals in System Settings → Notifications."
                            }
                        }
                    }
                if alertsEnabled {
                    HStack {
                        Slider(value: $alertThresholdC, in: 70...105, step: 1)
                            .accessibilityLabel("CPU alert threshold")
                            .accessibilityValue(TemperatureFormat.string(alertThresholdC, fahrenheit: useFahrenheit))
                        Text(TemperatureFormat.string(alertThresholdC, fahrenheit: useFahrenheit))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Toggle("Log to CSV", isOn: $csvLogging)
                if csvLogging, let url = SharedStore.csvLogURL {
                    Button("Show log file") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                }
            }
            .font(.system(size: 12))
            .padding(.top, 6)
        } label: {
            Text("Settings").font(.system(size: 12))
        }
    }

    private var menuBarModulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar modules")
                .font(.caption)
                .fontWeight(.medium)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 8
            ) {
                Toggle("CPU", isOn: $cpuModuleVisible)
                Toggle("Memory", isOn: $memoryModuleVisible)
                Toggle("Network", isOn: $networkModuleVisible)
                Toggle("Battery", isOn: $batteryModuleVisible)
                Toggle("Disk", isOn: $diskModuleVisible)
            }
            .toggleStyle(.checkbox)
        }
        .font(.system(size: 12))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("v\(appVersion)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var temperatureHistorySummary: String {
        let values = model.history.compactMap(\.cpuTempC)
        guard let current = values.last, let minimum = values.min(), let maximum = values.max() else {
            return "No CPU temperature history available"
        }
        return "CPU temperature, current \(TemperatureFormat.string(current, fahrenheit: useFahrenheit)), minimum \(TemperatureFormat.string(minimum, fahrenheit: useFahrenheit)), maximum \(TemperatureFormat.string(maximum, fahrenheit: useFahrenheit))"
    }
}
