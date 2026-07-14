import XCTest
@testable import MacVitals

final class SystemMetricsTests: XCTestCase {
    @MainActor
    func testPollIntervalNormalizationRejectsUnsafePreferenceValues() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 3_601, .greatestFiniteMagnitude] {
            XCTAssertEqual(SensorViewModel.normalizedPollInterval(value), 5)
        }
        XCTAssertEqual(SensorViewModel.normalizedPollInterval(1), 1)
        XCTAssertEqual(SensorViewModel.normalizedPollInterval(10), 10)
        XCTAssertEqual(SensorViewModel.normalizedPollInterval(3_600), 3_600)
    }

    func testCPUUsageUsesTickDeltasAndIncludesNiceTimeAsUserTime() throws {
        let previous = CPUTickSample(user: 100, system: 50, nice: 10, idle: 840)
        let current = CPUTickSample(user: 150, system: 70, nice: 20, idle: 860)

        let usage = try XCTUnwrap(SystemMetricMath.cpu(current: current, previous: previous))

        XCTAssertEqual(usage.total, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(usage.user, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(usage.system, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(usage.idle, 0.2, accuracy: 0.000_001)
    }

    func testCPUUsageRejectsZeroDeltaAndCounterRegression() {
        let sample = CPUTickSample(user: 10, system: 20, nice: 30, idle: 40)
        XCTAssertNil(SystemMetricMath.cpu(current: sample, previous: sample))

        let regressed = CPUTickSample(user: 9, system: 20, nice: 30, idle: 40)
        XCTAssertNil(SystemMetricMath.cpu(current: regressed, previous: sample))
    }

    func testNetworkRatesAndSessionDeltas() throws {
        let previous = NetworkCounterSample(interfaceName: "en0", receivedBytes: 1_000, sentBytes: 2_000)
        let current = NetworkCounterSample(interfaceName: "en0", receivedBytes: 4_000, sentBytes: 3_000)

        let result = try XCTUnwrap(SystemMetricMath.network(current: current, previous: previous, elapsed: 2))

        XCTAssertEqual(result.download, 1_500, accuracy: 0.000_001)
        XCTAssertEqual(result.upload, 500, accuracy: 0.000_001)
        XCTAssertEqual(result.downloaded, 3_000)
        XCTAssertEqual(result.uploaded, 1_000)
    }

    func testNetworkRatesRejectInvalidTimingInterfaceChangesAndCounterRegression() {
        let previous = NetworkCounterSample(interfaceName: "en0", receivedBytes: 100, sentBytes: 100)
        let same = NetworkCounterSample(interfaceName: "en0", receivedBytes: 200, sentBytes: 200)
        let switched = NetworkCounterSample(interfaceName: "en1", receivedBytes: 200, sentBytes: 200)
        let regressed = NetworkCounterSample(interfaceName: "en0", receivedBytes: 99, sentBytes: 200)

        for elapsed in [0, -1, 121, .infinity, .nan] {
            XCTAssertNil(SystemMetricMath.network(current: same, previous: previous, elapsed: elapsed))
        }
        XCTAssertNil(SystemMetricMath.network(current: switched, previous: previous, elapsed: 1))
        XCTAssertNil(SystemMetricMath.network(current: regressed, previous: previous, elapsed: 1))
    }

    func testPageByteConversionDetectsOverflow() {
        XCTAssertEqual(SystemMetricMath.pageBytes(4, pageSize: 4_096), 16_384)
        XCTAssertEqual(SystemMetricMath.pageBytes(0, pageSize: UInt64.max), 0)
        XCTAssertNil(SystemMetricMath.pageBytes(UInt64.max, pageSize: 2))
    }

    func testMemoryMathTreatsFileBackedAndPurgeablePagesAsReclaimable() throws {
        let memory = try XCTUnwrap(SystemMetricMath.memory(
            totalBytes: 1_000,
            pageSize: 10,
            internalPages: 60,
            purgeablePages: 10,
            wiredPages: 10,
            compressorPages: 5,
            externalPages: 20
        ))

        XCTAssertEqual(memory.used, 650)
        XCTAssertEqual(memory.available, 350)
        XCTAssertEqual(memory.wired, 100)
        XCTAssertEqual(memory.compressed, 50)
        XCTAssertEqual(memory.cached, 300)
    }

    func testMemoryMathRejectsIncoherentAndOverflowingCounters() {
        XCTAssertNil(SystemMetricMath.memory(
            totalBytes: 1_000,
            pageSize: 10,
            internalPages: 5,
            purgeablePages: 6,
            wiredPages: 0,
            compressorPages: 0,
            externalPages: 0
        ))
        XCTAssertNil(SystemMetricMath.memory(
            totalBytes: 1_000,
            pageSize: UInt64.max,
            internalPages: 2,
            purgeablePages: 0,
            wiredPages: 0,
            compressorPages: 0,
            externalPages: 0
        ))
        XCTAssertNil(SystemMetricMath.memory(
            totalBytes: 100,
            pageSize: 10,
            internalPages: 8,
            purgeablePages: 0,
            wiredPages: 3,
            compressorPages: 0,
            externalPages: 0
        ))
    }

    func testDiskMathAcceptsOnlyCoherentCapacityValues() throws {
        let disk = try XCTUnwrap(SystemMetricMath.disk(total: 1_000, available: 250))
        XCTAssertEqual(disk.totalBytes, 1_000)
        XCTAssertEqual(disk.availableBytes, 250)
        XCTAssertEqual(disk.usedBytes, 750)
        XCTAssertEqual(try XCTUnwrap(disk.usedFraction), 0.75, accuracy: 0.000_001)

        XCTAssertNil(SystemMetricMath.disk(total: nil, available: 1))
        XCTAssertNil(SystemMetricMath.disk(total: 0, available: 0))
        XCTAssertNil(SystemMetricMath.disk(total: 100, available: -1))
        XCTAssertNil(SystemMetricMath.disk(total: 100, available: 101))
    }

    func testMemoryDerivedFractionRequiresCoherentUsage() throws {
        let valid = MemoryMetrics(
            usedBytes: 600,
            availableBytes: 400,
            totalBytes: 1_000,
            wiredBytes: 100,
            compressedBytes: 50,
            cachedBytes: 200,
            pressure: .normal
        )
        XCTAssertEqual(try XCTUnwrap(valid.usedFraction), 0.6, accuracy: 0.000_001)

        var invalid = valid
        invalid.totalBytes = 0
        XCTAssertNil(invalid.usedFraction)
        invalid.totalBytes = 500
        XCTAssertNil(invalid.usedFraction)
    }

    func testMetricPercentFormattingRejectsInvalidValuesAndClampsHighValues() {
        XCTAssertEqual(MetricFormat.percent(nil), "—")
        XCTAssertEqual(MetricFormat.percent(.nan), "—")
        XCTAssertEqual(MetricFormat.percent(.infinity), "—")
        XCTAssertEqual(MetricFormat.percent(-0.01), "—")
        XCTAssertEqual(MetricFormat.percent(0), "0%")
        XCTAssertEqual(MetricFormat.percent(0.126), "13%")
        XCTAssertEqual(MetricFormat.percent(0.126, decimals: 1), "12.6%")
        XCTAssertEqual(MetricFormat.percent(2), "100%")
    }

    func testMetricRateFormattingAtUnitBoundaries() {
        XCTAssertEqual(MetricFormat.rate(nil), "—")
        XCTAssertEqual(MetricFormat.rate(-1), "—")
        XCTAssertEqual(MetricFormat.rate(.nan), "—")
        XCTAssertEqual(MetricFormat.rate(999), "999 B/s")
        XCTAssertEqual(MetricFormat.rate(1_000), "1.0 KB/s")
        XCTAssertEqual(MetricFormat.rate(100_000), "100 KB/s")
        XCTAssertEqual(MetricFormat.rate(1_000_000), "1.0 MB/s")
        XCTAssertEqual(MetricFormat.rate(1_000_000_000_000), "1.0 TB/s")
    }

    func testCompactRateFormattingAtUnitBoundaries() {
        XCTAssertEqual(MetricFormat.compactRate(nil), "—")
        XCTAssertEqual(MetricFormat.compactRate(.infinity), "—")
        XCTAssertEqual(MetricFormat.compactRate(999), "999B")
        XCTAssertEqual(MetricFormat.compactRate(1_000), "1K")
        XCTAssertEqual(MetricFormat.compactRate(999_999), "1000K")
        XCTAssertEqual(MetricFormat.compactRate(1_000_000), "1.0M")
        XCTAssertEqual(MetricFormat.compactRate(1_000_000_000), "1.0G")
    }

    func testDurationFormattingFloorsToWholeMinutes() {
        XCTAssertEqual(MetricFormat.duration(nil), "—")
        XCTAssertEqual(MetricFormat.duration(-1), "—")
        XCTAssertEqual(MetricFormat.duration(.nan), "—")
        XCTAssertEqual(MetricFormat.duration(.greatestFiniteMagnitude), "—")
        XCTAssertEqual(MetricFormat.duration(59), "0m")
        XCTAssertEqual(MetricFormat.duration(3_599), "59m")
        XCTAssertEqual(MetricFormat.duration(3_600), "1h 0m")
        XCTAssertEqual(MetricFormat.duration(5_430), "1h 30m")
    }

    func testByteFormattingHandlesMissingAndLargeValues() {
        XCTAssertEqual(MetricFormat.bytes(nil), "—")
        XCTAssertNotEqual(MetricFormat.bytes(0), "—")
        XCTAssertFalse(MetricFormat.bytes(UInt64.max).isEmpty)
    }

    func testSystemMetricsRoundTripsAllModelsAndEnums() throws {
        let metrics = makeSystemMetrics()

        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(SystemMetrics.self, from: data)

        XCTAssertEqual(decoded, metrics)
    }

    func testEmptyAndForwardCompatibleSystemMetricsSchemasDecode() throws {
        let empty = try JSONDecoder().decode(SystemMetrics.self, from: Data("{}".utf8))
        XCTAssertNil(empty.cpu)
        XCTAssertNil(empty.memory)
        XCTAssertNil(empty.network)
        XCTAssertNil(empty.battery)
        XCTAssertNil(empty.disk)

        let futureData = Data(#"{"futureModule":{"value":42}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SystemMetrics.self, from: futureData), empty)
    }

    func testUnknownEnumSchemaValuesAreRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(MemoryPressureLevel.self, from: Data(#""future""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(BatteryState.self, from: Data(#""calibrating""#.utf8)))
    }

    func testSnapshotValidationAcceptsCoherentSystemMetrics() {
        XCTAssertTrue(SharedStore.isValid(makeSnapshot(system: makeSystemMetrics())))
    }

    func testSnapshotValidationRejectsInvalidSystemMetricDomains() {
        var metrics = makeSystemMetrics()
        metrics.cpu?.totalUsage = 1.01
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))

        metrics = makeSystemMetrics()
        metrics.cpu?.physicalCoreCount = 9
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))

        metrics = makeSystemMetrics()
        metrics.cpu?.loadAverage1m = .infinity
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))

        metrics = makeSystemMetrics()
        metrics.cpu?.idleUsage = 0.60
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))

        metrics = makeSystemMetrics()
        metrics.memory?.availableBytes = 401
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))

        metrics = makeSystemMetrics()
        metrics.network?.downloadBytesPerSecond = 100_000_000_001
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))

        metrics = makeSystemMetrics()
        metrics.network?.interfaceName = "en0\nspoofed"
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))

        metrics = makeSystemMetrics()
        metrics.battery?.percentage = -0.01
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))

        metrics = makeSystemMetrics()
        metrics.disk?.availableBytes = 1_001
        XCTAssertFalse(SharedStore.isValid(makeSnapshot(system: metrics)))
    }

    func testLegacySnapshotWithoutSystemMetricsStillDecodesAndValidates() throws {
        let encoded = try JSONEncoder().encode(makeSnapshot(system: makeSystemMetrics()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "system")

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SensorSnapshot.self, from: data)

        XCTAssertNil(decoded.system)
        XCTAssertTrue(SharedStore.isValid(decoded))
    }

    func testModulePresentationsUseAccessiblePlaceholdersWithoutSnapshotData() {
        XCTAssertEqual(
            ModuleKind.cpu.presentation(snapshot: nil),
            ModulePresentation(symbol: "cpu", value: "—", accessibilityLabel: "CPU usage unavailable")
        )
        XCTAssertEqual(
            ModuleKind.memory.presentation(snapshot: nil),
            ModulePresentation(symbol: "memorychip", value: "—", accessibilityLabel: "Memory used unavailable")
        )
        XCTAssertEqual(
            ModuleKind.network.presentation(snapshot: nil),
            ModulePresentation(
                symbol: "arrow.up.arrow.down",
                value: "↓— ↑—",
                accessibilityLabel: "Network download unavailable, upload unavailable"
            )
        )
        XCTAssertEqual(
            ModuleKind.battery.presentation(snapshot: nil),
            ModulePresentation(symbol: "battery.0percent", value: "—", accessibilityLabel: "Battery unavailable")
        )
        XCTAssertEqual(
            ModuleKind.disk.presentation(snapshot: nil),
            ModulePresentation(symbol: "internaldrive", value: "—", accessibilityLabel: "Startup disk used unavailable")
        )
    }

    func testFreshInstallModuleDefaultsKeepThermalsPlusCPUOnly() {
        XCTAssertEqual(ModuleKind.allCases.filter(\.defaultVisibility), [.cpu])
    }

    func testCPUModulePresentationMapsUsageIconTitleAndAccessibility() {
        let presentation = ModuleKind.cpu.presentation(snapshot: makeSnapshot(system: makeSystemMetrics()))

        XCTAssertEqual(
            presentation,
            ModulePresentation(symbol: "cpu", value: "45%", accessibilityLabel: "CPU usage 45%")
        )
    }

    func testMemoryModulePresentationMapsUsedFractionIconTitleAndAccessibility() {
        let presentation = ModuleKind.memory.presentation(snapshot: makeSnapshot(system: makeSystemMetrics()))

        XCTAssertEqual(
            presentation,
            ModulePresentation(symbol: "memorychip", value: "60%", accessibilityLabel: "Memory used 60%")
        )
    }

    func testNetworkModulePresentationMapsBothRatesIconTitleAndAccessibility() {
        let presentation = ModuleKind.network.presentation(snapshot: makeSnapshot(system: makeSystemMetrics()))

        XCTAssertEqual(
            presentation,
            ModulePresentation(
                symbol: "arrow.up.arrow.down",
                value: "↓2K ↑500B",
                accessibilityLabel: "Network download 1.5 KB/s, upload 500 B/s"
            )
        )
    }

    func testChargingBatteryModulePresentationUsesBoltIconTitleAndAccessibility() {
        let presentation = ModuleKind.battery.presentation(snapshot: makeSnapshot(system: makeSystemMetrics()))

        XCTAssertEqual(
            presentation,
            ModulePresentation(symbol: "battery.100percent.bolt", value: "75%", accessibilityLabel: "Battery 75%")
        )
    }

    func testDiskModulePresentationMapsUsedFractionIconTitleAndAccessibility() {
        let presentation = ModuleKind.disk.presentation(snapshot: makeSnapshot(system: makeSystemMetrics()))

        XCTAssertEqual(
            presentation,
            ModulePresentation(symbol: "internaldrive", value: "75%", accessibilityLabel: "Startup disk used 75%")
        )
    }

    private func makeSystemMetrics() -> SystemMetrics {
        SystemMetrics(
            cpu: CPUMetrics(
                totalUsage: 0.45,
                userUsage: 0.30,
                systemUsage: 0.15,
                idleUsage: 0.55,
                loadAverage1m: 1.2,
                loadAverage5m: 1.0,
                loadAverage15m: 0.8,
                logicalCoreCount: 8,
                physicalCoreCount: 4
            ),
            memory: MemoryMetrics(
                usedBytes: 600,
                availableBytes: 400,
                totalBytes: 1_000,
                wiredBytes: 100,
                compressedBytes: 50,
                cachedBytes: 200,
                pressure: .warning
            ),
            network: NetworkMetrics(
                interfaceName: "en0",
                downloadBytesPerSecond: 1_500,
                uploadBytesPerSecond: 500,
                sessionDownloadedBytes: 3_000,
                sessionUploadedBytes: 1_000
            ),
            battery: BatteryMetrics(
                percentage: 0.75,
                state: .charging,
                isOnACPower: true,
                timeRemaining: 3_600,
                health: "Good",
                isLowPowerModeEnabled: false
            ),
            disk: DiskMetrics(totalBytes: 1_000, availableBytes: 250)
        )
    }

    private func makeSnapshot(system: SystemMetrics?) -> SensorSnapshot {
        SensorSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 1_000_000),
            cpuTempC: 55,
            gpuTempC: 50,
            socTempC: 45,
            cpuPowerW: 8,
            gpuPowerW: 2,
            fans: [],
            sensorCount: 0,
            allSensors: [],
            thermalPressure: "Nominal",
            useFahrenheit: false,
            diagnostics: "test",
            fanAvailability: .noneReported,
            system: system
        )
    }
}
