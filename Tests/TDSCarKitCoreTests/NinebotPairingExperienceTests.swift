import Foundation
import XCTest
@testable import TDSCarKitCore

final class NinebotPairingExperienceTests: XCTestCase {
    func testScanWindowAndPhysicalConfirmationUseDifferentDeadlines() {
        let scan = NinebotPairingWindow(startedAt: 100, duration: 30)
        let pairing = NinebotPairingWindow(startedAt: 100, duration: 60)
        XCTAssertEqual(scan.remaining(at: 100), 30)
        XCTAssertEqual(scan.remaining(at: 129.1), 1)
        XCTAssertEqual(scan.remaining(at: 130), 0)
        XCTAssertEqual(pairing.remaining(at: 130), 30)
        XCTAssertEqual(pairing.remaining(at: 160), 0)
        XCTAssertEqual(pairing.remaining(at: 300), 0)
    }
    func testInvalidOrReversedClockCannotGrowOrCrashCountdown() {
        let window = NinebotPairingWindow(startedAt: 100, duration: 60)
        XCTAssertEqual(window.remaining(at: 90), 60)
        XCTAssertEqual(window.remaining(at: .nan), 0)
        XCTAssertEqual(window.remaining(at: .infinity), 0)
        XCTAssertEqual(NinebotPairingWindow(startedAt: .infinity, duration: 60).remaining(at: 0), 0)
        XCTAssertEqual(NinebotPairingWindow(startedAt: 0, duration: .greatestFiniteMagnitude).remaining(at: 0), 0)
        XCTAssertEqual(NinebotPairingWindow(startedAt: 0, duration: -1).remaining(at: 0), 0)
    }
    func testOldFutureAndInvalidDiscoveryTimestampsAreNotSelectable() {
        XCTAssertTrue(NinebotPairingWindow.isFresh(lastSeen: 100, now: 100))
        XCTAssertTrue(NinebotPairingWindow.isFresh(lastSeen: 100, now: 110))
        XCTAssertFalse(NinebotPairingWindow.isFresh(lastSeen: 100, now: 110.01))
        XCTAssertFalse(NinebotPairingWindow.isFresh(lastSeen: 100, now: 99))
        XCTAssertFalse(NinebotPairingWindow.isFresh(lastSeen: .nan, now: 100))
        XCTAssertFalse(NinebotPairingWindow.isFresh(lastSeen: 100, now: .infinity))
    }
    func testUnavailableRSSIDoesNotAppearAsStrongSignal() {
        for value in [Int?.none, 127, 0, -128] {
            XCTAssertEqual(NinebotPairingWindow.signal(value), "信号未知")
        }
        XCTAssertEqual(NinebotPairingWindow.signal(-55), "信号较强")
        XCTAssertEqual(NinebotPairingWindow.signal(-75), "信号一般")
        XCTAssertEqual(NinebotPairingWindow.signal(-95), "信号较弱")
    }
    func testOnlySuccessfulAuthenticationIsShownAsCompleted() {
        for phase in [NinebotPairingPhase.connecting, .discovering, .preparing, .needsPairing, .pairing, .authenticating, .failed] {
            let presentation = NinebotPairingPresentation(phase: phase, isPairing: true)
            XCTAssertNotEqual(presentation.step, .complete)
            XCTAssertFalse(presentation.title.contains("已验证"))
        }
        let verified = NinebotPairingPresentation(phase: .paired, isPairing: false)
        XCTAssertEqual(verified.step, .complete)
        XCTAssertFalse(verified.isWorking)
    }
    func testProjectionIsNotPresentedAsNewPairingOrVideoProof() {
        for phase in [NinebotPairingPhase.connecting, .discovering, .preparing, .starting, .active] {
            let presentation = NinebotPairingPresentation(phase: phase, isPairing: false)
            XCTAssertNil(presentation.step)
            XCTAssertFalse(presentation.title.contains("配对"))
            XCTAssertFalse(presentation.title.contains("出画"))
        }
    }
    func testCheckingSavedCredentialsDoesNotPermitPairingWriteOrNavigationStart() {
        let prepare = VehicleBLEFrame(src: 0x3e, dst: 0x04, command: 0x5b, index: 0)
        let authenticate = VehicleBLEFrame(src: 0x3e, dst: 0x04, command: 0x5d, index: 0, payload: Data(repeating: 1, count: 14))
        for frame in [prepare, authenticate] {
            XCTAssertTrue(VehicleNavigationPolicy.permits(frame, pairing: false, authenticated: false, wantsNavigation: false))
        }
        let write = VehicleBLEFrame(src: 0x3e, dst: 0x04, command: 0x5c, index: 0, payload: Data(repeating: 1, count: 32))
        let start = VehicleBLEFrame(src: 0x3e, dst: 0x23, command: 0x71, index: 0, payload: Data([1]))
        XCTAssertFalse(VehicleNavigationPolicy.permits(write, pairing: false, authenticated: false, wantsNavigation: false))
        XCTAssertFalse(VehicleNavigationPolicy.permits(start, pairing: false, authenticated: true, wantsNavigation: false))
    }
    func testVerifyingAnotherVehicleKeepsExplicitSelectionAcrossSaveAndRestore() throws {
        let first = NinebotVehicle(id: UUID(), name: "My Ninebot", protocolVersion: 2, serialLength: 14)
        let second = NinebotVehicle(id: UUID(), name: "My Ninebot", protocolVersion: 3, serialLength: 16)
        var garage = NinebotVehicleSelection(); garage.save(first); garage.select(first.id)
        garage.save(second)
        let restored = try JSONDecoder().decode(NinebotVehicleSelection.self, from: JSONEncoder().encode(garage))
        XCTAssertEqual(restored.selected?.id, first.id)
        XCTAssertEqual(restored.vehicles.count, 2)
    }
}
