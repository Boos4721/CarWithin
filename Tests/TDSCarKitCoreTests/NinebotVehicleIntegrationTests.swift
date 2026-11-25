import Foundation
import XCTest
@testable import TDSCarKitCore

final class NinebotVehicleIntegrationTests: XCTestCase {
    func testRestoringMissingOrLegacyBindingClearsAnotherVehicle() {
        let first = NinebotVehicle(id: UUID(), name: "First", protocolVersion: 2, serialLength: 14)
        let second = NinebotVehicle(id: UUID(), name: "Second", protocolVersion: 3, serialLength: 16)
        var garage = NinebotVehicleSelection()
        garage.save(first); garage.save(second); garage.select(first.id)
        garage.restore(second.id)
        XCTAssertEqual(garage.selected, second)
        garage.restore(UUID())
        XCTAssertNil(garage.selected)
        garage.select(first.id); garage.restore(nil)
        XCTAssertNil(garage.selected)
        XCTAssertEqual(garage.vehicles.count, 2)
    }

    func testAuthenticatedFrameRejectsReplayAndTamperingWithoutConsumingSerial() throws {
        let sender = V2Crypto(), receiver = V2Crypto()
        for crypto in [sender, receiver] {
            try crypto.setAuthParam(Data(0..<16))
            try crypto.setKey(Data(16..<48), Data(0..<16))
            crypto.startSerial()
        }
        let plain = try VehicleBLEFrame(src: 0x3e, dst: 0x23, command: 0x71, index: 0, payload: Data([1])).encode()
        let wire = try sender.encrypt(plain)
        var tampered = wire
        tampered[4] ^= 1
        XCTAssertThrowsError(try receiver.decrypt(tampered))
        XCTAssertEqual(try receiver.decrypt(wire), plain)
        XCTAssertThrowsError(try receiver.decrypt(wire))
        let next = try sender.encrypt(plain)
        XCTAssertEqual(try receiver.decrypt(next), plain)
    }

    func testAuthenticationCandidateRejectionsPersistAcrossTransportRetries() {
        let pending = Data(repeating: 1, count: 32), confirmed = Data(repeating: 2, count: 32)
        var attempts = VehicleAuthenticationAttempts()
        XCTAssertEqual(attempts.remaining(from: [pending, confirmed, pending]), [pending, confirmed])
        attempts.reject(pending)
        XCTAssertEqual(attempts.remaining(from: [pending, confirmed]), [confirmed])
        attempts.reject(confirmed)
        XCTAssertTrue(attempts.remaining(from: [pending, confirmed]).isEmpty)
        XCTAssertEqual(VehicleAuthenticationAttempts().remaining(from: [pending, confirmed]), [pending, confirmed])
    }

    func testDiscoveryCombinesSplitEvidenceAndBlocksUnsupportedProtocol() throws {
        func advertisement(_ version: UInt8) -> Data {
            let payload: [UInt8] = [51, version, 4]
            let checksum = ~payload.reduce(UInt8(0), { $0 &+ $1 })
            return Data([0x4e, 0x42] + payload + [checksum])
        }
        var evidence = DiscoveryEvidence()
        XCTAssertFalse(evidence.merge(manufacturerData: nil, localName: "My Ninebot", isConnectable: true))
        XCTAssertFalse(evidence.isEligible)
        XCTAssertTrue(evidence.merge(manufacturerData: advertisement(2), localName: nil, isConnectable: nil))
        XCTAssertTrue(evidence.isEligible)
        XCTAssertTrue(evidence.advertisement!.isPowerConnected)
        var invalid = advertisement(2); invalid[invalid.count - 1] ^= 1
        evidence.merge(manufacturerData: invalid, localName: nil, isConnectable: nil)
        XCTAssertTrue(evidence.isEligible)
        evidence.merge(manufacturerData: advertisement(4), localName: nil, isConnectable: true)
        evidence.merge(manufacturerData: advertisement(2), localName: nil, isConnectable: true)
        XCTAssertFalse(evidence.isEligible)
        XCTAssertThrowsError(try Advertisement.parse(manufacturerData: invalid))
    }

    func testFrameAssemblerBoundsGarbageAndHandlesConsecutiveFragmentedFrames() throws {
        let first = try VehicleBLEFrame(src: 0x23, dst: 0x3e, command: 0x71, index: 0).encode()
        let second = try VehicleBLEFrame(src: 0x23, dst: 0x3e, command: 0x71, index: 0xff, payload: Data([0])).encode()
        let assembler = VehicleBLEFrameAssembler(encrypted: false, maxBufferedBytes: 255)
        XCTAssertTrue(assembler.append(Data(repeating: 0xff, count: 10000)).isEmpty)
        XCTAssertLessThanOrEqual(assembler.bufferedByteCount, 255)
        let combined = first + second
        var output: [Data] = []
        for byte in combined { output += assembler.append(Data([byte])) }
        XCTAssertEqual(output, [first, second])
        XCTAssertEqual(assembler.bufferedByteCount, 0)
        let oversized = VehicleBLEFrame(src: 0x3e, dst: 0x23, command: 0x71, index: 0,
                                        payload: Data(repeating: 0, count: 243))
        XCTAssertThrowsError(try oversized.encode())
    }
}
