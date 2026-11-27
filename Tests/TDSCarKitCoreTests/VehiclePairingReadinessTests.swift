import Foundation
import XCTest
@testable import TDSCarKitCore

final class VehiclePairingReadinessTests: XCTestCase {
    private func ready(src: UInt8 = 0x04, dst: UInt8 = 0x3e, command: UInt8 = 0x5c,
                       index: UInt8 = 0, payload: Data = Data()) -> VehicleBLEFrame {
        VehicleBLEFrame(src: src, dst: dst, command: command, index: index, payload: payload)
    }

    func testButtonWindowStartsOnReadyReplyAndIsNotExtendedByDuplicates() {
        var state = VehiclePairingReadiness(startedAt: 10)
        state.didSendRequest()
        XCTAssertNil(state.confirmationWindow)
        XCTAssertTrue(state.acceptReady(ready(), at: 17))
        XCTAssertEqual(state.confirmationWindow?.remaining(at: 17), 60)
        XCTAssertFalse(state.acceptReady(ready(), at: 40))
        XCTAssertEqual(state.confirmationWindow?.remaining(at: 40), 37)
        XCTAssertFalse(state.hasExpired(at: 76.9))
        XCTAssertTrue(state.hasExpired(at: 77))
    }

    func testUnrelatedAndMalformedRepliesCannotPromptButtonPress() {
        for frame in [ready(src: 0x23), ready(dst: 0x04), ready(command: 0x71),
                      ready(index: 1), ready(payload: Data([0]))] {
            var state = VehiclePairingReadiness(startedAt: 0)
            XCTAssertFalse(state.acceptReady(frame, at: 6))
            XCTAssertNil(state.confirmationWindow)
        }
    }

    func testLateReadyReplyCannotReopenAnExpiredPreparationWindow() {
        var state = VehiclePairingReadiness(startedAt: 10)
        XCTAssertFalse(state.acceptReady(ready(), at: 30))
        XCTAssertNil(state.confirmationWindow)
    }

    func testReadinessRecoveryCountsSentRequestsAndStopsAfterReady() {
        var state = VehiclePairingReadiness(startedAt: 0)
        for _ in 0..<7 { state.didSendRequest() }
        XCTAssertFalse(state.needsReadinessRecovery)
        state.didSendRequest()
        XCTAssertTrue(state.needsReadinessRecovery)
        XCTAssertTrue(state.acceptReady(ready(), at: 16))
        XCTAssertFalse(state.needsReadinessRecovery)
    }

    func testPreparationHasBoundedDeadlineAndRejectsInvalidClock() {
        let state = VehiclePairingReadiness(startedAt: 10)
        XCTAssertFalse(state.hasExpired(at: 29.9))
        XCTAssertTrue(state.hasExpired(at: 30))
        XCTAssertTrue(state.hasExpired(at: .nan))
        XCTAssertTrue(state.hasExpired(at: 9))
    }

    func testSerialLengthUsesAdvertisementAndInfersBoundedMissingLength() {
        XCTAssertEqual(VehiclePrecommunication.serialLength(payloadCount: 30, advertisedLength: 14), 14)
        XCTAssertEqual(VehiclePrecommunication.serialLength(payloadCount: 32, advertisedLength: 14), 14)
        XCTAssertEqual(VehiclePrecommunication.serialLength(payloadCount: 32, advertisedLength: nil), 16)
        XCTAssertEqual(VehiclePrecommunication.serialLength(payloadCount: 80, advertisedLength: nil), 64)
    }

    func testInvalidSerialLengthAndTruncatedPrecommunicationFailClosed() {
        for length in [0, -1, 65] {
            XCTAssertNil(VehiclePrecommunication.serialLength(payloadCount: 80, advertisedLength: length))
        }
        XCTAssertNil(VehiclePrecommunication.serialLength(payloadCount: 29, advertisedLength: 14))
        for count in [0, 15, 16, 81, 300] {
            XCTAssertNil(VehiclePrecommunication.serialLength(payloadCount: count, advertisedLength: nil))
        }
    }
}
