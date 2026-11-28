import XCTest
@testable import TDSCarKitCore

final class BMSOverviewPresentationTests: XCTestCase {
    private func reading(family: BMSFamily = .ant, fields: Set<String> = ["charge", "voltage", "current", "power"],
                         voltage: Double = 82, charge: Int = 78, sensors: Bool = true) -> ANTBMSReading {
        var value = ANTBMSReading(voltage: voltage, current: 0, power: 0, stateOfCharge: charge,
            stateOfHealth: nil, stateCode: 1, capacityAh: 0, remainingAh: 0, cells: sensors ? [4.0, 4.013] : [],
            temperatures: sensors ? [24] : [], mosTemperature: nil, protectionBits: 0, warningBits: 0)
        value.family = family; value.available = fields
        return value
    }
    func testOverviewSeparatesPrimaryAndHealthAndPreservesZeroFields() {
        var capabilities = BMSFieldCapabilities(family: .ant); capabilities.observe(reading())
        let view = BMSOverviewPresentation(capabilities: capabilities)
        XCTAssertEqual(view.primaryFields, [.charge, .voltage, .current, .power])
        XCTAssertEqual(view.healthFields, [.temperature, .cellDelta])
    }
    func testBroadcastOnlyShowsSOCInsteadOfEmptyGrid() {
        let view = BMSOverviewPresentation(capabilities: BMSFieldCapabilities(family: .xiaoha))
        XCTAssertEqual(view.primaryFields, [.charge]); XCTAssertTrue(view.healthFields.isEmpty)
    }
    func testSparseDataDoesNotErasePreviouslyConfirmedFields() {
        var capabilities = BMSFieldCapabilities(family: .ant); capabilities.observe(reading())
        let initial = BMSOverviewPresentation(capabilities: capabilities)
        capabilities.observe(reading(fields: ["voltage"]))
        let later = BMSOverviewPresentation(capabilities: capabilities)
        XCTAssertEqual(later.primaryFields, initial.primaryFields)
        XCTAssertEqual(later.healthFields, initial.healthFields)
    }
    func testUnknownJK04FieldsAreNotAddedToOverview() {
        var capabilities = BMSFieldCapabilities(family: .jikong)
        var value = reading(family: .jikong, fields: ["voltage"])
        value.extraDetails["协议"] = "JK04"
        capabilities.observe(value)
        let view = BMSOverviewPresentation(capabilities: capabilities)
        XCTAssertEqual(view.primaryFields, [.voltage]); XCTAssertEqual(view.healthFields, [.cellDelta])
    }
    func testEmptySessionDoesNotProduceSummary() {
        let summary = BMSRecordSummary(statistics: ANTBMSSessionStatistics())
        XCTAssertFalse(summary.hasSamples); XCTAssertEqual(summary.details, "")
        XCTAssertEqual(summary.charge, "电量未提供")
    }
    func testSummaryUsesFrozenDurationAndFullSessionExtrema() {
        var stats = ANTBMSSessionStatistics(); stats.startRecording(at: 100)
        stats.append(ANTBMSSample(reading: reading(), uptime: 100), now: 100)
        stats.append(ANTBMSSample(reading: reading(voltage: 80, charge: 76), uptime: 101), now: 101)
        stats.finishRecording(at: 110)
        let summary = BMSRecordSummary(statistics: stats)
        XCTAssertTrue(summary.hasSamples); XCTAssertEqual(summary.duration, "0 分 10 秒")
        XCTAssertEqual(summary.charge, "78% → 76%")
        XCTAssertEqual(summary.coverage, "有效数据覆盖 10%")
        XCTAssertTrue(summary.details.contains("80.00–82.00 V"))
        XCTAssertTrue(summary.details.contains("0 W"))
    }
    func testBroadcastRecordDoesNotInventPowerVoltageOrCellDelta() {
        var stats = ANTBMSSessionStatistics()
        let value = reading(family: .xiaoha, fields: ["charge"], sensors: false)
        stats.append(ANTBMSSample(reading: value, uptime: 100), now: 100)
        let summary = BMSRecordSummary(statistics: stats)
        XCTAssertTrue(summary.hasSamples); XCTAssertEqual(summary.details, "")
        XCTAssertEqual(summary.coverage, "完整度未保存")
    }
    func testWaitingTimeLowersCoverageAndSingleFrameDoesNotBecomeContinuousData() {
        var stats = ANTBMSSessionStatistics(); stats.startRecording(at: 0)
        stats.append(ANTBMSSample(reading: reading(), uptime: 30), now: 30); stats.finishRecording(at: 60)
        let summary = BMSRecordSummary(statistics: stats)
        XCTAssertEqual(summary.duration, "1 分 0 秒"); XCTAssertEqual(summary.coverage, "有效数据覆盖 0%")
    }
    func testCapacityOverviewTracksSourcesAndKeepsMissingValuesUnknown() {
        var capabilities = BMSFieldCapabilities(family: .luxing)
        var data = reading(family: .luxing, fields: ["voltage", "capacity", "remaining"], sensors: false)
        data.extraDetails["剩余容量来源"] = "计算值：SOC × 额定容量，非直接测量"
        capabilities.observe(data)
        XCTAssertEqual(BMSOverviewPresentation(capabilities: capabilities).primaryFields, [.voltage, .capacity, .remaining])
        XCTAssertTrue(capabilities.explanation(of: .remaining, reading: data).contains("计算值"))
        XCTAssertTrue(capabilities.explanation(of: .capacity, reading: data).contains("配置容量"))
        let missing = reading(family: .luxing, fields: ["voltage"], sensors: false)
        capabilities.observe(missing)
        XCTAssertEqual(capabilities.availability(of: .remaining, reading: missing), .temporarilyMissing)
        XCTAssertEqual(ANTBMSCardConfiguration.Field.remaining.text(missing), "--Ah")
        XCTAssertEqual(BMSFieldCapabilities(family: .xiaoha).availability(of: .capacity, reading: nil), .notProvided)
        var jk = BMSFieldCapabilities(family: .jikong)
        var jk04 = missing; jk04.family = .jikong; jk04.extraDetails["协议"] = "JK04"; jk.observe(jk04)
        XCTAssertEqual(jk.availability(of: .remaining, reading: nil), .notProvided)
    }

}
