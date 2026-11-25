import Foundation
import XCTest
@testable import TDSCarKitCore

final class BMSRecommendationTests: XCTestCase {
    private func reading(_ family: BMSFamily = .ant, fields: Set<String> = ["charge", "voltage", "current", "power"],
                         cells: [Double?] = [3.2, 3.21], temperature: Bool = true, variant: String? = nil) -> ANTBMSReading {
        var value = ANTBMSReading(voltage: 82, current: 0, power: 0, stateOfCharge: 0,
            stateOfHealth: nil, stateCode: 1, capacityAh: 0, remainingAh: 0, cells: cells,
            temperatures: temperature ? [20] : [], mosTemperature: nil, protectionBits: 0, warningBits: 0)
        value.family = family; value.available = fields
        if let variant { value.extraDetails["协议"] = variant }
        return value
    }
    func testHumanNamesKeepStableProtocolIDsAndSeparateTechnicalDetails() {
        XCTAssertEqual(BMSFamily.ant.title, "蚂蚁保护板")
        XCTAssertEqual(BMSFamily.jikong.title, "极空保护板")
        XCTAssertEqual(BMSFamily.yanyang.title, "彦阳保护板")
        XCTAssertEqual(BMSFamily.lanbao.title, "蓝宝电量计")
        XCTAssertEqual(BMSFamily.jikong.rawValue, "jikong")
        XCTAssertTrue(BMSFamily.jikong.protocolDescription.contains("JK04"))
        XCTAssertEqual(BMSFamily.ant.shortName, "蚂蚁")
    }
    func testRecommendationUsesActualValidFieldsAndKeepsRealZeroValues() {
        var caps = BMSFieldCapabilities(family: .ant)
        let data = reading(); caps.observe(data)
        XCTAssertEqual(caps.recommendedFields, [.charge, .voltage, .current, .temperature])
        XCTAssertEqual(caps.availability(of: .charge, reading: data), .available)
        XCTAssertEqual(ANTBMSCardConfiguration.Field.charge.text(data), "0%")
        XCTAssertEqual(ANTBMSCardConfiguration.Field.current.text(data), "+0.0A")
    }
    func testTemporaryMissingFrameAndDisconnectDoNotShrinkLayout() {
        var caps = BMSFieldCapabilities(family: .ant); caps.observe(reading())
        let initial = caps.recommendedFields
        let sparse = reading(fields: ["voltage"], cells: [], temperature: false)
        caps.observe(sparse)
        XCTAssertEqual(caps.recommendedFields, initial)
        XCTAssertEqual(caps.availability(of: .current, reading: sparse), .temporarilyMissing)
        XCTAssertEqual(caps.availability(of: .temperature, reading: nil), .temporarilyMissing)
    }
    func testJK04AndLegacyYYOnlyRecommendConfirmedCapabilities() {
        var jk = BMSFieldCapabilities(family: .jikong)
        jk.observe(reading(.jikong, fields: ["voltage"], temperature: false, variant: "JK04"))
        XCTAssertEqual(jk.recommendedFields, [.voltage, .cellDelta])
        XCTAssertEqual(jk.availability(of: .charge, reading: nil), .notProvided)
        var yy = BMSFieldCapabilities(family: .yanyang)
        yy.observe(reading(.yanyang, fields: ["voltage"], variant: "YYBMS 旧 A（待实物验证）"))
        XCTAssertEqual(yy.recommendedFields, [.voltage, .temperature, .cellDelta])
        XCTAssertEqual(yy.availability(of: .current, reading: nil), .notProvided)
    }
    func testProtocolVariantChangeClearsPreviousCapabilityEvidence() {
        var caps = BMSFieldCapabilities(family: .jikong)
        caps.observe(reading(.jikong, variant: "JK02 32S"))
        caps.observe(reading(.jikong, fields: ["voltage"], temperature: false, variant: "JK04"))
        XCTAssertFalse(caps.observed.contains(.current))
        XCTAssertEqual(caps.recommendedFields, [.voltage, .cellDelta])
    }
    func testBroadcastAndMeterDeltaExplainTheirActualSources() {
        var broadcast = BMSFieldCapabilities(family: .xiaoha)
        let data = reading(.xiaoha, fields: ["charge"], cells: [], temperature: false)
        broadcast.observe(data)
        XCTAssertEqual(broadcast.recommendedFields, [.charge])
        XCTAssertEqual(broadcast.availability(of: .voltage, reading: data), .notProvided)
        var meter = BMSFieldCapabilities(family: .lanbao)
        var m = reading(.lanbao, fields: ["voltage"], cells: [], temperature: false)
        m.reportedCellDelta = 0.01; meter.observe(m)
        XCTAssertEqual(meter.explanation(of: .cellDelta, reading: m), "设备报告压差")
        XCTAssertEqual(meter.recommendedFields, [.voltage, .cellDelta])
    }
    func testUnknownFieldsAndSingleCellDoNotClaimUnsupportedOrZeroDelta() {
        var caps = BMSFieldCapabilities(family: .mingtang)
        caps.observe(reading(.mingtang, fields: ["voltage"], cells: [3.2], temperature: false))
        XCTAssertEqual(caps.availability(of: .current, reading: nil), .waiting)
        XCTAssertEqual(caps.availability(of: .cellDelta, reading: nil), .waiting)
        let previous = caps
        caps.observe(reading(.ant))
        XCTAssertEqual(caps, previous)
    }
    func testAutoRenderPreservesCustomFieldsAndExistingLayoutsDefaultToCustom() {
        var card = ANTBMSCardConfiguration(savedFields: ["cellDelta", "charge", "voltage"], modeRawValue: 0)
        let rendered = card.resolving(recommendedFields: [.charge])
        XCTAssertEqual(rendered.fields, [.charge])
        XCTAssertEqual(card.fields, [.cellDelta, .charge, .voltage])
        card.mode = .custom
        XCTAssertEqual(card.resolving(recommendedFields: [.charge]).fields, card.fields)
        XCTAssertEqual(ANTBMSCardConfiguration().mode, .custom)
        XCTAssertEqual(ANTBMSCardConfiguration(modeRawValue: 99).mode, .custom)
        card.mode = .automatic; card.set(.power, visible: true)
        XCTAssertEqual(card.mode, .custom)
    }
}
