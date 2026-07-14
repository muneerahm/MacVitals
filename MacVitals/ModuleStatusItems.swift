import AppKit
import SwiftUI

@MainActor
final class MacVitalsAppDelegate: NSObject, NSApplicationDelegate {
    let model = SensorViewModel()
    private var statusCoordinator: ModuleStatusItemCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = ModuleStatusItemCoordinator(model: model)
        statusCoordinator = coordinator
        model.snapshotDidChange = { [weak coordinator] snapshot in
            coordinator?.update(snapshot: snapshot)
        }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

@MainActor
private final class ModuleStatusItemCoordinator {
    private let model: SensorViewModel
    private let thermalItem: ThermalStatusItem
    private var items: [ModuleKind: ModuleStatusItem] = [:]
    private var defaultsObserver: NSObjectProtocol?

    init(model: SensorViewModel) {
        self.model = model
        // The first MacVitals status item occupies the position nearest the
        // system items. Keep Thermals there so optional modules yield first.
        thermalItem = ThermalStatusItem(model: model)
        refreshVisibility()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: SharedStore.defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshVisibility()
                self.thermalItem.update(snapshot: self.model.snapshot)
            }
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    func update(snapshot: SensorSnapshot) {
        thermalItem.update(snapshot: snapshot)
        for item in items.values { item.update(snapshot: snapshot) }
    }

    private func refreshVisibility() {
        for kind in ModuleKind.allCases {
            if isVisible(kind) {
                if items[kind] == nil {
                    let item = ModuleStatusItem(kind: kind, model: model)
                    items[kind] = item
                    if let snapshot = model.snapshot { item.update(snapshot: snapshot) }
                }
            } else if let item = items.removeValue(forKey: kind) {
                item.close()
            }
        }
    }

    private func isVisible(_ kind: ModuleKind) -> Bool {
        guard let defaults = SharedStore.defaults else { return kind.defaultVisibility }
        if defaults.object(forKey: kind.visibilityKey) == nil { return kind.defaultVisibility }
        return defaults.bool(forKey: kind.visibilityKey)
    }
}

@MainActor
private final class ThermalStatusItem: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(model: SensorViewModel) {
        super.init()

        statusItem.autosaveName = "com.macvitals.app.status.thermals"
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = "MacVitals Thermals"
        }
        update(snapshot: nil)
    }

    func update(snapshot: SensorSnapshot?) {
        guard let button = statusItem.button else { return }
        let defaults = SharedStore.defaults
        let useFahrenheit = defaults?.bool(forKey: SharedStore.fahrenheitKey) ?? false
        let isHot = snapshot?.thermalPressure == "Serious" || snapshot?.thermalPressure == "Critical"
        let symbol = isHot ? "flame.fill" : "fanblades"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacVitals Thermals")
        image?.isTemplate = true
        button.image = image

        let temperature = TemperatureFormat.string(snapshot?.cpuTempC, fahrenheit: useFahrenheit)
        button.title = temperature
        button.setAccessibilityLabel("MacVitals Thermals, CPU temperature \(temperature)")
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@MainActor
private final class ModuleStatusItem: NSObject {
    private let kind: ModuleKind
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(kind: ModuleKind, model: SensorViewModel) {
        self.kind = kind
        super.init()

        statusItem.autosaveName = "com.macvitals.app.status.\(kind.identifier)"
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: kind.content(model: model))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = kind.tooltip
        }
        update(snapshot: nil)
    }

    func update(snapshot: SensorSnapshot?) {
        guard let button = statusItem.button else { return }
        let presentation = kind.presentation(snapshot: snapshot)
        let image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: kind.tooltip)
        image?.isTemplate = true
        button.image = image
        button.title = presentation.value
        button.setAccessibilityLabel(presentation.accessibilityLabel)
    }

    func close() {
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

enum ModuleKind: CaseIterable, Equatable {
    case cpu, memory, network, battery, disk

    var visibilityKey: String {
        switch self {
        case .cpu: SharedStore.cpuModuleVisibleKey
        case .memory: SharedStore.memoryModuleVisibleKey
        case .network: SharedStore.networkModuleVisibleKey
        case .battery: SharedStore.batteryModuleVisibleKey
        case .disk: SharedStore.diskModuleVisibleKey
        }
    }

    var tooltip: String {
        switch self {
        case .cpu: "MacVitals CPU"
        case .memory: "MacVitals Memory"
        case .network: "MacVitals Network"
        case .battery: "MacVitals Battery"
        case .disk: "MacVitals Startup Disk"
        }
    }

    var identifier: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memory"
        case .network: "network"
        case .battery: "battery"
        case .disk: "disk"
        }
    }

    var defaultVisibility: Bool { self == .cpu }

    @MainActor @ViewBuilder
    func content(model: SensorViewModel) -> some View {
        switch self {
        case .cpu: CPUMenuView(model: model)
        case .memory: MemoryMenuView(model: model)
        case .network: NetworkMenuView(model: model)
        case .battery: BatteryMenuView(model: model)
        case .disk: DiskMenuView(model: model)
        }
    }

    func presentation(snapshot: SensorSnapshot?) -> ModulePresentation {
        switch self {
        case .cpu:
            let value = MetricFormat.percent(snapshot?.system?.cpu?.totalUsage)
            return ModulePresentation(symbol: "cpu", value: value, accessibilityLabel: "CPU usage \(spoken(value))")
        case .memory:
            let value = MetricFormat.percent(snapshot?.system?.memory?.usedFraction)
            return ModulePresentation(symbol: "memorychip", value: value, accessibilityLabel: "Memory used \(spoken(value))")
        case .network:
            let network = snapshot?.system?.network
            let compact = "↓\(MetricFormat.compactRate(network?.downloadBytesPerSecond)) ↑\(MetricFormat.compactRate(network?.uploadBytesPerSecond))"
            let accessible = "Network download \(spoken(MetricFormat.rate(network?.downloadBytesPerSecond))), upload \(spoken(MetricFormat.rate(network?.uploadBytesPerSecond)))"
            return ModulePresentation(symbol: "arrow.up.arrow.down", value: compact, accessibilityLabel: accessible)
        case .battery:
            let battery = snapshot?.system?.battery
            let value = MetricFormat.percent(battery?.percentage)
            return ModulePresentation(symbol: batterySymbol(battery), value: value, accessibilityLabel: "Battery \(spoken(value))")
        case .disk:
            let value = MetricFormat.percent(snapshot?.system?.disk?.usedFraction)
            return ModulePresentation(symbol: "internaldrive", value: value, accessibilityLabel: "Startup disk used \(spoken(value))")
        }
    }

    private func spoken(_ value: String) -> String {
        value == "—" ? "unavailable" : value
    }

    private func batterySymbol(_ battery: BatteryMetrics?) -> String {
        guard let battery else { return "battery.0percent" }
        if battery.state == .charging { return "battery.100percent.bolt" }
        return switch battery.percentage {
        case 0.75...: "battery.100percent"
        case 0.5...: "battery.75percent"
        case 0.25...: "battery.50percent"
        default: "battery.25percent"
        }
    }
}

struct ModulePresentation: Equatable {
    let symbol: String
    let value: String
    let accessibilityLabel: String
}
