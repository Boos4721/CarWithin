import XCTest
@testable import TDSCarKitCore

final class ANTBMSCardConfigurationTests: XCTestCase {
    private func reading(cells: [Double?] = [4.1, nil, 4.106], temperatures: [Double?] = [nil, 14],
                         protection: UInt64 = 0) -> ANTBMSReading {
        ANTBMSReading(voltage: 82.78, current: -12.3, power: -1018, stateOfCharge: 78,
            stateOfHealth: 100, stateCode: 4, capacityAh: 170, remainingAh: 131.92,
            cells: cells, temperatures: temperatures, mosTemperature: 15,
            protectionBits: protection, warningBits: 0)
    }

    func testExistingUsersKeepAllSixMetricsInTwoLines() {
        let card = ANTBMSCardConfiguration()
        XCTAssertEqual(card.size, .medium)
        XCTAssertEqual(card.lines(for: reading()), ["ANT  78%  82.78V  14°C", "-12.3A  -1018W  压差 6mV"])
    }

    func testCompactCardKeepsVoltageAndSpreadOnOneLine() {
        let card = ANTBMSCardConfiguration(savedFields: ANTBMSCardConfiguration.compactFields.map(\.rawValue))
        XCTAssertEqual(card.lines(for: reading()), ["ANT  78%  82.78V  压差 6mV"])
    }

    func testSavedFieldsNormalizeDuplicatesAndUnknownValues() {
        let card = ANTBMSCardConfiguration(savedFields: ["cellDelta", "unknown", "voltage", "cellDelta"], sizeRawValue: 99)
        XCTAssertEqual(card.fields, [.voltage, .cellDelta])
        XCTAssertEqual(card.size, .medium)
        XCTAssertEqual(ANTBMSCardConfiguration(savedFields: []).fields, ANTBMSCardConfiguration.Field.allCases)
        XCTAssertEqual(ANTBMSCardConfiguration(savedFields: ["unknown"]).fields, ANTBMSCardConfiguration.Field.allCases)
    }

    func testLastMetricCannotBeHiddenAndSelectionCanBeSavedAndRestored() {
        var card = ANTBMSCardConfiguration(savedFields: ["cellDelta"], sizeRawValue: 2)
        XCTAssertFalse(card.set(.cellDelta, visible: false))
        XCTAssertTrue(card.set(.voltage, visible: true))
        XCTAssertTrue(card.set(.cellDelta, visible: false))
        let restored = ANTBMSCardConfiguration(savedFields: card.fields.map(\.rawValue), sizeRawValue: card.size.rawValue)
        XCTAssertEqual(restored, card)
        XCTAssertEqual(restored.fields, [.voltage])
    }

    func testMissingSensorsAreUnknownAndAlarmSurvivesFieldSelection() {
        let card = ANTBMSCardConfiguration(savedFields: ["temperature", "cellDelta"])
        XCTAssertEqual(card.lines(for: reading(cells: [nil, nil], temperatures: [], protection: 1)),
            ["ANT  --°C  压差 --mV · 告警"])
    }

}
