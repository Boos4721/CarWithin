import XCTest
@testable import TDSCarKitCore

final class ANTBMSSessionStatisticsTests: XCTestCase {
    private func sample(at uptime: TimeInterval, voltage: Double = 82, charge: Int = 78,
                        current: Double = -10, power: Int = -820,
                        temperatures: [Double?] = [14], cells: [Double?] = [4.1, 4.106]) -> ANTBMSSample {
        let reading = ANTBMSReading(voltage: voltage, current: current, power: power, stateOfCharge: charge,
            stateOfHealth: nil, stateCode: 4, capacityAh: 170, remainingAh: 130, cells: cells,
            temperatures: temperatures, mosTemperature: nil, protectionBits: 0, warningBits: 0)
        return ANTBMSSample(reading: reading, uptime: uptime)
    }

    func testDuplicatesStaleFramesClockReversalAndOutagesDoNotCountAsRidingTime() {
        var statistics = ANTBMSSessionStatistics()
        XCTAssertTrue(statistics.append(sample(at: 100), now: 100))
        XCTAssertFalse(statistics.append(sample(at: 100), now: 101))
        XCTAssertFalse(statistics.append(sample(at: 99), now: 101))
        XCTAssertFalse(statistics.append(sample(at: 101), now: 110))
        XCTAssertTrue(statistics.append(sample(at: 102), now: 102))
        XCTAssertTrue(statistics.append(sample(at: 200), now: 200))
        XCTAssertEqual(statistics.sampleCount, 3)
        XCTAssertEqual(statistics.sampledSeconds, 2)
    }

    func testStatisticsPreserveSocRangeAndSignedCurrentMagnitude() throws {
        var statistics = ANTBMSSessionStatistics()
        statistics.append(sample(at: 100), now: 100)
        statistics.append(sample(at: 101, voltage: 80, charge: 75, current: 12, power: 960,
            temperatures: [nil, 28], cells: [4.0, nil, 4.02]), now: 101)
        XCTAssertEqual(statistics.firstCharge, 78)
        XCTAssertEqual(statistics.lastCharge, 75)
        XCTAssertEqual(statistics.minimumVoltage, 80)
        XCTAssertEqual(statistics.maximumVoltage, 82)
        XCTAssertEqual(statistics.peakAbsoluteCurrent, 12)
        XCTAssertEqual(statistics.peakAbsolutePower, 960)
        XCTAssertEqual(statistics.maximumTemperature, 28)
        XCTAssertEqual(try XCTUnwrap(statistics.maximumCellDelta), 0.02, accuracy: 0.000001)
        let restored = try JSONDecoder().decode(ANTBMSSessionStatistics.self, from: JSONEncoder().encode(statistics))
        XCTAssertEqual(restored, statistics)
    }

    func testMissingSensorsStayUnknownInSummary() {
        var statistics = ANTBMSSessionStatistics()
        statistics.append(sample(at: 100, temperatures: [nil], cells: [nil]), now: 100)
        XCTAssertNil(statistics.maximumTemperature)
        XCTAssertNil(statistics.maximumCellDelta)
    }

    func testTrendIsBoundedWithoutDiscardingWholeSessionStatistics() {
        var statistics = ANTBMSSessionStatistics()
        for index in 0..<1000 { statistics.append(sample(at: Double(index)), now: Double(index)) }
        XCTAssertEqual(statistics.sampleCount, 1000)
        XCTAssertEqual(statistics.sampledSeconds, 999)
        XCTAssertEqual(statistics.points.count, 120)
        XCTAssertGreaterThan(statistics.points.first?.elapsed ?? 0, 0)
    }
}
