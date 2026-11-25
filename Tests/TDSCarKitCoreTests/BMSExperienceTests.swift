import Foundation
import XCTest
@testable import TDSCarKitCore

final class BMSExperienceTests: XCTestCase {
    private func state(_ phase: BMSConnectionPhase, fresh: Bool = false, age: Double? = nil,
                       family: BMSFamily = .ant, selected: Bool = true, enabled: Bool = true) -> BMSConnectionPresentation {
        BMSConnectionPresentation(enabled: enabled, hasSelection: selected, family: family, phase: phase,
            hasFreshData: fresh, lastReadingAge: age, reason: "连接详情")
    }
    func testBluetoothConnectionAndSubscriptionAreNotShownAsTelemetrySuccess() {
        for phase in [BMSConnectionPhase.connecting, .discovering, .subscribing, .waitingForData] {
            let view = state(phase)
            XCTAssertEqual(view.tone, .working)
            XCTAssertNotEqual(view.title, "电池数据正常")
        }
        XCTAssertEqual(state(.receiving, fresh: true, age: 0).tone, .good)
    }
    func testExpiredSamplesOfferRetryAndNeverShowDataNormal() {
        let view = state(.receiving, age: 6)
        XCTAssertEqual(view.title, "数据已过期")
        XCTAssertEqual(view.action, .retry)
        XCTAssertTrue(view.detail.contains("6 秒前"))
        XCTAssertEqual(state(.reconnecting, age: 20).title, "数据已过期 · 正在重连")
    }
    func testBroadcastSOCIsExplicitlyLabelledAndCanExpire() {
        let view = state(.receiving, fresh: true, age: 2, family: .xiaoha)
        XCTAssertEqual(view.title, "广播电量正常")
        XCTAssertTrue(view.detail.contains("仅提供电量"))
        XCTAssertEqual(state(.receiving, age: 7, family: .xiaoha).tone, .attention)
    }
    func testDisabledAndRecoverableFailuresHaveRelevantActions() {
        XCTAssertEqual(state(.receiving, fresh: true, enabled: false).action, .enable)
        XCTAssertEqual(state(.bluetoothUnavailable).action, .settings)
        XCTAssertEqual(state(.needsAccess).action, .access)
        XCTAssertEqual(state(.needsFamily).action, .family)
        XCTAssertEqual(state(.needsFamily, selected: false).action, .scan)
        XCTAssertEqual(state(.scanning, selected: false).action, .scan)
        XCTAssertEqual(state(.receiving, fresh: true).action, .none)
    }
    func testSavedManualFamilyWinsOverChangedAdvertisementHints() {
        XCTAssertEqual(BMSSelectionPolicy.family(saved: "jbd", inferred: .ant), .jbd)
        XCTAssertEqual(BMSSelectionPolicy.family(saved: "jikong", inferred: nil), .jikong)
        XCTAssertEqual(BMSSelectionPolicy.family(saved: nil, inferred: .yanyang), .yanyang)
        XCTAssertNil(BMSSelectionPolicy.family(saved: nil, inferred: nil))
        XCTAssertNil(BMSSelectionPolicy.family(saved: "removed-family", inferred: .ant))
    }
    func testMissingAndInvalidCellsPreserveSlotNumbersWithoutAffectingExtrema() {
        let view = BMSCellSummary(cells: [3.2, nil, .nan, 3.3, .infinity, 0, 8])
        XCTAssertEqual(view.cells.count, 7)
        XCTAssertEqual(view.validCount, 2)
        XCTAssertEqual(view.lowestSlots, [1]); XCTAssertEqual(view.highestSlots, [4])
        XCTAssertEqual(view.minimum, 3.2); XCTAssertEqual(view.maximum, 3.3)
        XCTAssertEqual(view.delta!, 0.1, accuracy: 0.00001)
    }
    func testEmptyOrSingleValidCellCannotProducePackCellDelta() {
        XCTAssertNil(BMSCellSummary(cells: []).delta)
        XCTAssertNil(BMSCellSummary(cells: [nil, nil]).minimum)
        XCTAssertNil(BMSCellSummary(cells: [nil, 3.2]).delta)
        let equal = BMSCellSummary(cells: [3.2, 3.2])
        XCTAssertEqual(equal.delta, 0)
        XCTAssertEqual(equal.highestSlots, [1, 2])
    }
    func testCellGridIsBoundedToSupportedANTSlotLimit() {
        let view = BMSCellSummary(cells: Array(repeating: 3.2, count: 80))
        XCTAssertEqual(view.cells.count, 64)
        XCTAssertEqual(view.validCount, 64)
    }
}
