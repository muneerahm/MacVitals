import XCTest
@testable import MacVitals

final class MacVitalsTests: XCTestCase {
    func testSMCParameterLayoutMatchesKernelABI() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.size, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.alignment, 4)
    }

    func testSMCNumericDecoders() {
        let floatBits = Float(2_000.5).bitPattern
        let floatBytes = [
            UInt8(floatBits & 0xff),
            UInt8((floatBits >> 8) & 0xff),
            UInt8((floatBits >> 16) & 0xff),
            UInt8((floatBits >> 24) & 0xff),
        ]
        XCTAssertEqual(SMCValueDecoder.decode(type: "flt ", bytes: floatBytes), 2_000.5)
        XCTAssertEqual(SMCValueDecoder.decode(type: "fpe2", bytes: [0x17, 0x70]), 1_500)
        XCTAssertEqual(SMCValueDecoder.decode(type: "sp78", bytes: [0x19, 0x80]), 25.5)
        XCTAssertEqual(SMCValueDecoder.decode(type: "ui16", bytes: [0x12, 0x34]), 0x1234)
        XCTAssertNil(SMCValueDecoder.decode(type: "flt ", bytes: [0, 0, 0xc0, 0x7f]))
        XCTAssertNil(SMCValueDecoder.decode(type: "????", bytes: [1]))
    }

    func testEnergyUnitDecoderRejectsUnknownAndNonFiniteValues() {
        XCTAssertEqual(EnergyUnitDecoder.joules(raw: 2_000, unit: "mJ"), 2)
        XCTAssertEqual(EnergyUnitDecoder.joules(raw: 2_000_000, unit: "µJ"), 2)
        XCTAssertEqual(EnergyUnitDecoder.joules(raw: 2_000_000_000, unit: "nJ"), 2)
        XCTAssertNil(EnergyUnitDecoder.joules(raw: 1, unit: "watts"))
        XCTAssertNil(EnergyUnitDecoder.joules(raw: .infinity, unit: "nJ"))
    }

    func testTemperatureClassifiersCoverModernAndIntelFamilies() {
        XCTAssertTrue(SensorReader.isCPUSensor("pACC MTR Temp Sensor4"))
        XCTAssertTrue(SensorReader.isCPUSensor("PMU tdie1"))
        XCTAssertTrue(SensorReader.isCPUSensor("Tp01"))
        XCTAssertTrue(SensorReader.isCPUSensor("Te05"))
        XCTAssertTrue(SensorReader.isCPUSensor("TC0P"))
        XCTAssertFalse(SensorReader.isCPUSensor("PMU tcal0"))

        XCTAssertTrue(SensorReader.isGPUSensor("GPU MTR Temp Sensor1"))
        XCTAssertTrue(SensorReader.isGPUSensor("Tg0f"))
        XCTAssertTrue(SensorReader.isGPUSensor("TG0P"))

        XCTAssertTrue(SensorReader.isSoCSensor("SOC MTR Temp Sensor2"))
        XCTAssertTrue(SensorReader.isSoCSensor("PMU tcal0"))
        XCTAssertTrue(SensorReader.isSoCSensor("Ts0a"))
        XCTAssertTrue(SensorReader.isSoCSensor("Tm0P"))
    }

    func testFanValuesAreBoundedBeforeIntegerConversion() {
        let valid = FanReading(id: 0, name: "Fan", rpm: 1_999.6, minRPM: 1_200, maxRPM: 5_000, targetRPM: nil)
        XCTAssertEqual(valid.displayRPM, "2000")
        XCTAssertEqual(valid.normalized ?? -1, (1_999.6 - 1_200) / (5_000 - 1_200), accuracy: 0.0001)

        let infinite = FanReading(id: 0, name: "Fan", rpm: .infinity, minRPM: nil, maxRPM: nil, targetRPM: nil)
        XCTAssertNil(infinite.validRPM)
        XCTAssertEqual(infinite.displayRPM, "—")

        let excessive = FanReading(id: 0, name: "Fan", rpm: 100_001, minRPM: nil, maxRPM: nil, targetRPM: nil)
        XCTAssertNil(excessive.validRPM)
    }

    func testHistoryUsesThirtyMinuteWindowAndCap() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let old = HistoryPoint(date: now.addingTimeInterval(-1_801), cpuTempC: 40, gpuTempC: nil, maxFanRPM: nil)
        let recent = HistoryPoint(date: now.addingTimeInterval(-60), cpuTempC: 50, gpuTempC: nil, maxFanRPM: nil)
        let latest = HistoryPoint(date: now, cpuTempC: 55, gpuTempC: nil, maxFanRPM: nil)

        XCTAssertEqual(SharedStore.trimmedHistory([old, recent], adding: latest).map(\.date), [recent.date, latest.date])
        XCTAssertEqual(SharedStore.trimmedHistory([recent], adding: latest, cap: 1), [latest])
    }

    func testSnapshotValidationRejectsUnsafeValues() {
        var snapshot = makeSnapshot()
        XCTAssertTrue(SharedStore.isValid(snapshot))

        snapshot.cpuTempC = 1_000
        XCTAssertFalse(SharedStore.isValid(snapshot))

        snapshot = makeSnapshot()
        snapshot.fans[0].rpm = .greatestFiniteMagnitude
        XCTAssertFalse(SharedStore.isValid(snapshot))
    }

    func testOlderSnapshotWithoutFanAvailabilityStillDecodes() throws {
        let encoded = try JSONEncoder().encode(makeSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fanAvailability")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SensorSnapshot.self, from: legacyData)
        XCTAssertNil(decoded.fanAvailability)
    }

    func testTemperatureFormatting() {
        XCTAssertEqual(TemperatureFormat.string(0, fahrenheit: false), "0°C")
        XCTAssertEqual(TemperatureFormat.string(0, fahrenheit: true), "32°F")
        XCTAssertEqual(TemperatureFormat.string(nil, fahrenheit: false), "—")
    }

    private func makeSnapshot() -> SensorSnapshot {
        SensorSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 1_000_000),
            cpuTempC: 55,
            gpuTempC: 50,
            socTempC: 45,
            cpuPowerW: 8,
            gpuPowerW: 2,
            fans: [FanReading(id: 0, name: "Fan", rpm: 2_000, minRPM: 1_200, maxRPM: 5_000, targetRPM: 2_100)],
            sensorCount: 1,
            allSensors: [TempReading(name: "PMU tdie1", celsius: 55)],
            thermalPressure: "Nominal",
            useFahrenheit: false,
            diagnostics: "test",
            fanAvailability: .available
        )
    }
}
