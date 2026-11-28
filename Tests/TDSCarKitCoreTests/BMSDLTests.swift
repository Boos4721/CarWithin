import Foundation
import XCTest
@testable import TDSCarKitCore

/// Synthetic vectors cross-checked against the reference layout, SEC2 and NIST SP 800-38A.
final class BMSDLTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] { BMSReadOnlyProtocol.hex(s)! }
    private func le16(_ b: inout [UInt8], _ i: Int, _ n: Int) {
        b[i] = UInt8(truncatingIfNeeded: n); b[i + 1] = UInt8(truncatingIfNeeded: n >> 8)
    }
    private func le32(_ b: inout [UInt8], _ i: Int, _ n: Int) {
        for j in 0..<4 { b[i+j] = UInt8(truncatingIfNeeded: n >> (j*8)) }
    }
    private func payload(full: Bool = true) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: full ? 142 : 110)
        let o = full ? 32 : 0, base = full ? 78 : 46
        if full { b.replaceSubrange(0..<4, with: Array("BAT3".utf8)) }
        b[o] = 15; b[o+1] = 20
        le32(&b, o+2, 300); le32(&b, o+6, 264)
        le16(&b, o+10, 804); le16(&b, o+12, 3); le32(&b, o+14, 24); le16(&b, o+18, 88)
        b[o+20] = 1; b[o+21] = 21
        for i in 0..<20 { le16(&b, base+i*2, 4010+i) }
        if full { le16(&b, 68, 22); le32(&b, 70, 125); le32(&b, 74, 5) }
        return b
    }
    private struct Peer {
        let shared: [UInt8]
        let request: [UInt8]
    }
    private func handshake(_ p: BMSReadOnlyProtocol, at now: Double = 0) throws -> Peer {
        let request = [UInt8](try XCTUnwrap(p.nextRequest(now: now)))
        XCTAssertTrue(p.permitsRequest(Data(request)))
        let privateKey = [UInt8](repeating: 0, count: 31) + [2]
        let pair = try BMSDLSession.keyPair(privateKey: privateKey)
        let shared = try BMSDLSession.secret(privateKey: privateKey, peer: Array(request[13..<77]))
        let serial = UInt16(BMSBytes(request).le16(5))
        let answer = BMSDLSession.frame(function: 0, content: pair.publicKey, serial: serial, response: true)
        for byte in answer { XCTAssertTrue(p.append(Data([byte]), now: now+0.1).isEmpty) }
        let read = [UInt8](try XCTUnwrap(p.nextRequest(now: now+0.2)))
        XCTAssertTrue(p.permitsRequest(Data(read)))
        XCTAssertFalse(BMSReadOnlyProtocol.permits(Data(read), family: .dl)) // Context is mandatory.
        return Peer(shared: shared, request: try BMSDLSession.crypt(read, shared: shared, encrypt: false))
    }
    private func response(_ peer: Peer, content: [UInt8]? = nil, serial: UInt16? = nil, function: UInt8 = 0x17) throws -> [UInt8] {
        let seq = serial ?? UInt16(BMSBytes(peer.request).le16(5))
        return try BMSDLSession.crypt(BMSDLSession.frame(function: function, content: content ?? payload(), serial: seq, response: true), shared: peer.shared, encrypt: true)
    }
    func testIdentificationRequiresNameOrFullManufacturerMarker() {
        XCTAssertEqual(BMSFamily.identify(name: "dl-bms-01"), .dl)
        XCTAssertEqual(BMSFamily.identify(name: "", manufacturerID: 0x6c64, manufacturerData: Data(hex("646c6b6a6d6b01020304050600"))), .dl)
        XCTAssertNil(BMSFamily.identify(name: "UART", services: ["FFE0", "FFE2"]))
        XCTAssertNil(BMSFamily.identify(name: "", manufacturerID: 0x6c64))
        XCTAssertNil(BMSFamily.identify(name: "", manufacturerID: 0x6c64, manufacturerData: Data(hex("646c61626364"))))
        XCTAssertEqual(BMSFamily.dl.title, "电岭电量计")
        XCTAssertEqual(BMSFamily.dl.shortName, "电岭")
        XCTAssertEqual(BMSFamily.dl.channels, [.init("FFE0", "FFE1", "FFE2")])
        XCTAssertEqual(BMSFamily.luxing.channels, [.init("FFE0", "FFE2", "FFE1")])
    }
    func testCategoriesPartitionFamiliesWithStableOrderAndPreserveSavedIDs() throws {
        XCTAssertEqual(BMSFamily.Category.allCases, [.protectionBoard, .meter])
        XCTAssertEqual(BMSFamily.Category.protectionBoard.families, [.ant, .jikong, .yanyang, .jbd, .yadi, .mingtang, .xiaoha])
        XCTAssertEqual(BMSFamily.Category.meter.families, [.lanbao, .luxing, .dl])
        let grouped = BMSFamily.Category.allCases.flatMap { $0.families }
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(BMSFamily.allCases))
        for category in BMSFamily.Category.allCases {
            for family in category.families {
                XCTAssertEqual(family.category, category)
                XCTAssertEqual(try JSONDecoder().decode(BMSFamily.self, from: JSONEncoder().encode(family)), family)
            }
        }
        XCTAssertEqual(BMSFamily.dl.rawValue, "dl")
        XCTAssertEqual(BMSFamily.Category.protectionBoard.title, "保护板")
        XCTAssertEqual(BMSFamily.Category.meter.title, "电量计")
    }
    func testSecp256k1PublishedTwoGeneratorPointAndInvalidPublicKeys() throws {
        let pair = try BMSDLSession.keyPair(privateKey: [UInt8](repeating: 0, count: 31)+[2])
        XCTAssertEqual(pair.publicKey, hex("C6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE51AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A"))
        XCTAssertThrowsError(try BMSDLSession.secret(privateKey: pair.privateKey, peer: [UInt8](repeating: 0, count: 64)))
        XCTAssertThrowsError(try BMSDLSession.secret(privateKey: pair.privateKey, peer: [UInt8](repeating: 255, count: 64)))
        XCTAssertThrowsError(try BMSDLSession.keyPair(privateKey: [0]))
        XCTAssertThrowsError(try BMSDLSession.keyPair(privateKey: [UInt8](repeating: 0, count: 32)))
    }
    func testECDHMatchesBothPeersAndSessionsHaveFreshKeys() throws {
        let a = try BMSDLSession.keyPair(), b = try BMSDLSession.keyPair()
        XCTAssertNotEqual(a.publicKey, b.publicKey)
        XCTAssertEqual(try BMSDLSession.secret(privateKey: a.privateKey, peer: b.publicKey), try BMSDLSession.secret(privateKey: b.privateKey, peer: a.publicKey))
        let p = BMSReadOnlyProtocol(family: .dl), q = BMSReadOnlyProtocol(family: .dl)
        XCTAssertNotEqual(p.nextRequest(now: 0), q.nextRequest(now: 0))
    }
    func testAESCBCAgainstNISTKnownAnswerAndZeroPadding() throws {
        let shared = hex("2b7e151628aed2a6abf7158809cf4f3c000102030405060708090a0b0c0d0e0f")
        let input = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let expected = hex("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2")
        XCTAssertEqual(try BMSDLSession.crypt(input, shared: shared, encrypt: true), expected)
        XCTAssertEqual(try BMSDLSession.crypt(expected, shared: shared, encrypt: false), input)
        let padded = try BMSDLSession.crypt([1,2,3], shared: shared, encrypt: true)
        XCTAssertEqual(try BMSDLSession.crypt(padded, shared: shared, encrypt: false), [1,2,3]+[UInt8](repeating: 0, count: 13))
        XCTAssertThrowsError(try BMSDLSession.crypt([1], shared: shared, encrypt: false))
    }
    func testReadRequestPublishedVectorAndWhitelist() throws {
        XCTAssertEqual(BMSDLSession.frame(function: 0x17, content: [], serial: 1), hex("A55A00401701000100010000005901"))
        let p = BMSReadOnlyProtocol(family: .dl), first = try XCTUnwrap(p.nextRequest(now: 0))
        XCTAssertTrue(BMSReadOnlyProtocol.permits(first, family: .dl))
        XCTAssertTrue(p.permitsRequest(first))
        var wrong = first; wrong[4] = 5
        XCTAssertFalse(p.permitsRequest(wrong)); XCTAssertFalse(BMSReadOnlyProtocol.permits(wrong, family: .dl))
        XCTAssertFalse(p.permitsRequest(Data(BMSDLSession.frame(function: 0x17, content: [], serial: 2))))
        XCTAssertNil(p.nextRequest(now: 0.1))
        XCTAssertNotNil(p.nextRequest(now: 4))
        XCTAssertFalse(p.permitsRequest(first)) // Superseded serial.
    }
    func testFullLayoutMatchesReferenceAndSharedPresentation() throws {
        let r = try XCTUnwrap(BMSDLSession.decode(payload()))
        XCTAssertEqual(r.family, .dl); XCTAssertEqual(r.voltage, 80.4, accuracy: 0.001)
        XCTAssertEqual(r.current, 0.3, accuracy: 0.001); XCTAssertEqual(r.stateCode, 4)
        XCTAssertEqual(r.power, 24); XCTAssertEqual(r.stateOfCharge, 88)
        XCTAssertEqual(r.capacityAh, 30); XCTAssertEqual(r.remainingAh, 26.4, accuracy: 0.001)
        XCTAssertEqual(r.cells.count, 20); XCTAssertEqual(r.cells.last!, 4.029)
        XCTAssertEqual(r.cellDelta!, 0.022, accuracy: 0.0001)
        XCTAssertEqual(r.maximumTemperature, 21); XCTAssertNil(r.mosTemperature); XCTAssertNil(r.stateOfHealth)
        XCTAssertEqual(r.extraDetails["循环次数"], "5")
        XCTAssertFalse(r.available.contains("protection")); XCTAssertFalse(r.available.contains("warnings"))
        XCTAssertEqual(BMSFieldCapabilities.fields(in: r), Set(ANTBMSCardConfiguration.Field.allCases))
    }
    func testShortLayoutDoesNotInventCyclesAndComputesDelta() throws {
        let r = try XCTUnwrap(BMSDLSession.decode(payload(full: false)))
        XCTAssertEqual(r.voltage, 80.4, accuracy: 0.001); XCTAssertEqual(r.maximumTemperature, 21)
        XCTAssertNil(r.reportedCellDelta); XCTAssertEqual(r.cellDelta!, 0.019, accuracy: 0.0001)
        XCTAssertNil(r.extraDetails["循环次数"]); XCTAssertNil(r.extraDetails["循环容量"])
    }
    func testNegativeCurrentPowerTemperatureAndOldCellScaling() throws {
        var b = payload(); le16(&b, 44, -2); le32(&b, 46, -24); b[53] = 255
        le16(&b, 78, 53868)
        let r = try XCTUnwrap(BMSDLSession.decode(b))
        XCTAssertEqual(r.current, -0.2, accuracy: 0.001); XCTAssertEqual(r.power, -24); XCTAssertEqual(r.stateCode, 2)
        XCTAssertEqual(r.temperatures[0], -1); XCTAssertEqual(r.cells[0], 4.020)
    }
    func testZeroAndMissingFieldsStayDistinctAndCellIndicesArePreserved() throws {
        var b = payload(); le16(&b, 44, 0); le32(&b, 46, 0); le16(&b, 50, 0); le16(&b, 68, 0)
        b[53] = 128; le16(&b, 78, 0xffff); le16(&b, 82, 0)
        let r = try XCTUnwrap(BMSDLSession.decode(b))
        XCTAssertEqual(r.stateOfCharge, 0); XCTAssertTrue(r.available.contains("charge")); XCTAssertEqual(r.current, 0)
        XCTAssertEqual(r.stateCode, 1); XCTAssertEqual(r.reportedCellDelta, 0)
        XCTAssertNil(r.cells[0]); XCTAssertEqual(r.cells[1], 4.011); XCTAssertNil(r.cells[2]); XCTAssertNil(r.maximumTemperature)
        le16(&b, 50, 65535); le16(&b, 68, 65535); le32(&b, 34, -1); le32(&b, 38, -1); le32(&b, 74, -1)
        let missing = try XCTUnwrap(BMSDLSession.decode(b))
        XCTAssertFalse(missing.available.contains("charge")); XCTAssertFalse(missing.available.contains("capacity"))
        XCTAssertFalse(missing.available.contains("remaining")); XCTAssertNil(missing.reportedCellDelta)
        XCTAssertNil(missing.extraDetails["循环次数"])
    }
    func testTruncatedAndOutOfRangeLayoutsAreRejected() {
        XCTAssertNil(BMSDLSession.decode(Array(payload().prefix(100))))
        XCTAssertNil(BMSDLSession.decode([UInt8](repeating: 0, count: 10000)))
        for count in [0,33,255] { var b = payload(); b[33] = UInt8(count); XCTAssertNil(BMSDLSession.decode(b)) }
        var b = payload(); b[52] = 10; XCTAssertNil(BMSDLSession.decode(b))
        b = payload(); le16(&b, 42, 65535); XCTAssertNil(BMSDLSession.decode(b))
    }
    func testFragmentedEncryptedRoundTripAndPollingCadence() throws {
        let p = BMSReadOnlyProtocol(family: .dl), peer = try handshake(p)
        var result: [ANTBMSReading] = []
        for byte in try response(peer) { result += p.append(Data([byte]), now: 0.3) }
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].voltage, 80.4, accuracy: 0.001)
        XCTAssertNil(p.nextRequest(now: 0.5)); XCTAssertNotNil(p.nextRequest(now: 1.4))
    }
    func testEveryCiphertextSplitPointIsAccepted() throws {
        let p = BMSReadOnlyProtocol(family: .dl), firstPeer = try handshake(p)
        var peer = firstPeer
        for split in 0...160 {
            let answer = try response(peer)
            let r = p.append(Data(answer.prefix(split)), now: Double(split)*2+0.3)
                + p.append(Data(answer.dropFirst(split)), now: Double(split)*2+0.3)
            XCTAssertEqual(r.count, 1, "split \(split)")
            if split < 160 {
                let read = try XCTUnwrap(p.nextRequest(now: Double(split)*2+1.4))
                peer = Peer(shared: peer.shared, request: try BMSDLSession.crypt([UInt8](read), shared: peer.shared, encrypt: false))
            }
        }
    }
    func testWrongSerialFunctionAndPacketCountersDoNotConfirmData() throws {
        let p = BMSReadOnlyProtocol(family: .dl), peer = try handshake(p)
        XCTAssertTrue(p.append(Data(try response(peer, serial: 555)), now: 0.3).isEmpty)
        XCTAssertTrue(p.append(Data(try response(peer, function: 5)), now: 0.4).isEmpty)
        var frame = BMSDLSession.frame(function: 0x17, content: payload(), serial: UInt16(BMSBytes(peer.request).le16(5)), response: true)
        frame[7] = 2
        frame.removeLast(2); let checksum = frame.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        frame += [UInt8(truncatingIfNeeded: checksum), UInt8(checksum >> 8)]
        XCTAssertTrue(p.append(Data(try BMSDLSession.crypt(frame, shared: peer.shared, encrypt: true)), now: 0.5).isEmpty)
        XCTAssertEqual(p.append(Data(try response(peer)), now: 0.6).count, 1)
    }
    func testBadChecksumPaddingAndReplayDoNotRefreshData() throws {
        let p = BMSReadOnlyProtocol(family: .dl), peer = try handshake(p)
        let good = try response(peer)
        var plain = try BMSDLSession.crypt(good, shared: peer.shared, encrypt: false)
        plain[156] ^= 1
        XCTAssertTrue(p.append(Data(try BMSDLSession.crypt(plain, shared: peer.shared, encrypt: true)), now: 0.3).isEmpty)
        plain = try BMSDLSession.crypt(good, shared: peer.shared, encrypt: false); plain[159] = 1
        XCTAssertTrue(p.append(Data(try BMSDLSession.crypt(plain, shared: peer.shared, encrypt: true)), now: 0.4).isEmpty)
        XCTAssertEqual(p.append(Data(good+good), now: 0.5).count, 1)
        XCTAssertTrue(p.append(Data(good), now: 0.6).isEmpty)
        _ = p.nextRequest(now: 1.6)
        XCTAssertTrue(p.append(Data(good), now: 1.7).isEmpty)
    }
    func testInvalidHandshakeAndNoiseCannotStartReads() throws {
        let p = BMSReadOnlyProtocol(family: .dl), key = [UInt8](try XCTUnwrap(p.nextRequest(now: 0)))
        let serial = UInt16(BMSBytes(key).le16(5))
        let invalid = BMSDLSession.frame(function: 0, content: [UInt8](repeating: 0, count: 64), serial: serial, response: true)
        XCTAssertTrue(p.append(Data([9,8,7]+invalid), now: 0.1).isEmpty)
        XCTAssertNil(p.nextRequest(now: 1)); XCTAssertFalse(p.halted)
        let retry = try XCTUnwrap(p.nextRequest(now: 4))
        XCTAssertTrue(BMSDLSession.permitsHandshake(retry))
        let pair = try BMSDLSession.keyPair()
        let late = BMSDLSession.frame(function: 0, content: pair.publicKey, serial: serial, response: true)
        XCTAssertTrue(p.append(Data(late), now: 4.1).isEmpty); XCTAssertNil(p.nextRequest(now: 4.2))
    }
    func testTimedOutReplyAndOversizedInputRemainBoundedAndRetryable() throws {
        let p = BMSReadOnlyProtocol(family: .dl), peer = try handshake(p)
        XCTAssertTrue(p.append(Data(try response(peer)), now: 4).isEmpty)
        let retry = try XCTUnwrap(p.nextRequest(now: 4.1))
        let next = Peer(shared: peer.shared, request: try BMSDLSession.crypt([UInt8](retry), shared: peer.shared, encrypt: false))
        XCTAssertTrue(p.append(Data(repeating: 255, count: 10000), now: 4.2).isEmpty)
        XCTAssertEqual(p.append(Data(try response(next)), now: 4.3).count, 1)
    }
}
