import Foundation
import XCTest
@testable import TDSCarKitCore

final class NinebotScanDiagnosticsTests: XCTestCase {
    private func advertisement(_ version: UInt8 = 2) -> Data {
        let payload: [UInt8] = [51, version, 4]
        let checksum = ~payload.reduce(UInt8(0)) { $0 &+ $1 }
        return Data([0x4e, 0x42] + payload + [checksum])
    }
    private func record(_ scan: inout NinebotScanDiagnostics, id: UUID, name: String? = "Unknown", time: Double = 1,
                        services: [String] = [], manufacturer: Data? = nil, evidence: DiscoveryEvidence = .init(),
                        rssi: Int? = -50, connected: Bool = false) {
        scan.observe(id: id, name: name, rssi: rssi, services: services, manufacturerData: manufacturer,
                     evidence: evidence, now: time, systemConnected: connected)
    }
    func testGenericUARTAndNameAppearButCannotBecomePairingEvidence() throws {
        var scan = NinebotScanDiagnostics()
        let id = UUID()
        record(&scan, id: id, name: "Ninebot My Vehicle", services: [NinebotScanDiagnostics.uartService])
        let entry = try XCTUnwrap(scan.unrecognized.first)
        XCTAssertTrue(entry.hasUART); XCTAssertFalse(entry.recognized); XCTAssertFalse(entry.eligible)
        XCTAssertEqual(scan.recognizedCount, 0); XCTAssertEqual(scan.eligibleCount, 0)
        XCTAssertEqual(scan.packetCount, 1)
    }
    func testVerifiedSplitPacketsPromoteOnlyWithRealEligibility() throws {
        var scan = NinebotScanDiagnostics(), evidence = DiscoveryEvidence()
        let id = UUID()
        evidence.merge(manufacturerData: advertisement(), localName: nil, isConnectable: true)
        record(&scan, id: id, manufacturer: advertisement(), evidence: evidence)
        XCTAssertEqual(scan.recognizedCount, 1); XCTAssertEqual(scan.eligibleCount, 0)
        XCTAssertTrue(try XCTUnwrap(scan.entries[id]).reason.contains("尚缺广播名称"))
        evidence.merge(manufacturerData: nil, localName: "Real advertised name", isConnectable: nil)
        record(&scan, id: id, time: 2, evidence: evidence)
        XCTAssertEqual(scan.eligibleCount, 1); XCTAssertTrue(scan.unrecognized.isEmpty)
    }
    func testWrongManufacturerTruncationAndBadChecksumRemainVisible() throws {
        var scan = NinebotScanDiagnostics()
        var bad = advertisement(); bad[bad.count - 1] ^= 1
        for (data, reason) in [(Data([0x4c, 0, 1, 2]), "其他厂商"),
                               (Data([0x4e, 0x42]), "不完整"), (bad, "校验未通过")] {
            let id = UUID(); record(&scan, id: id, manufacturer: data)
            XCTAssertTrue(try XCTUnwrap(scan.entries[id]).reason.contains(reason))
        }
        XCTAssertEqual(scan.unrecognized.count, 3); XCTAssertEqual(scan.eligibleCount, 0)
    }
    func testBadPacketDoesNotRevokeVerifiedEvidence() throws {
        var scan = NinebotScanDiagnostics(), evidence = DiscoveryEvidence()
        let id = UUID()
        evidence.merge(manufacturerData: advertisement(), localName: "Car", isConnectable: true)
        record(&scan, id: id, evidence: evidence)
        var bad = advertisement(); bad[bad.count - 1] ^= 1
        evidence.merge(manufacturerData: bad, localName: nil, isConnectable: nil)
        record(&scan, id: id, time: 2, manufacturer: bad, evidence: evidence)
        XCTAssertTrue(try XCTUnwrap(scan.entries[id]).eligible)
        XCTAssertTrue(scan.unrecognized.isEmpty)
    }
    func testCapacityEvictsOldUnrecognizedWithoutHidingVerifiedVehicle() {
        var scan = NinebotScanDiagnostics(maximumDevices: 2), evidence = DiscoveryEvidence()
        let known = UUID(), old = UUID(), fresh = UUID()
        evidence.merge(manufacturerData: advertisement(), localName: "Car", isConnectable: true)
        record(&scan, id: known, time: 0, evidence: evidence)
        record(&scan, id: old, time: 1)
        record(&scan, id: fresh, time: 2)
        XCTAssertNotNil(scan.entries[known]); XCTAssertNil(scan.entries[old]); XCTAssertNotNil(scan.entries[fresh])
        XCTAssertEqual(scan.entries.count, 2); XCTAssertEqual(scan.capacityDrops, 1)
        XCTAssertEqual(NinebotScanDiagnostics(maximumDevices: 1000).maximumDevices, 100)
    }
    func testSystemConnectedDevicesAreVisibleWithoutClaimingBroadcastOrPairability() throws {
        var scan = NinebotScanDiagnostics()
        let id = UUID()
        record(&scan, id: id, services: [NinebotScanDiagnostics.uartService], connected: true)
        let item = try XCTUnwrap(scan.unrecognized.first)
        XCTAssertTrue(item.systemConnected); XCTAssertFalse(item.eligible)
        XCTAssertEqual(scan.packetCount, 0); XCTAssertEqual(scan.entries.count, 1)
    }
    func testMetadataMergesAndBoundsNamesAndServices() throws {
        var scan = NinebotScanDiagnostics()
        let id = UUID()
        record(&scan, id: id, name: String(repeating: "车", count: 100), services: ["ffe0"])
        record(&scan, id: id, name: nil, time: 2, services: ["FF00", "FFE0"])
        let item = try XCTUnwrap(scan.entries[id])
        XCTAssertEqual(item.name.count, 64); XCTAssertEqual(item.services, ["FF00", "FFE0"])
        XCTAssertEqual(item.lastSeen, 2); XCTAssertEqual(scan.entries.count, 1)
    }
    func testSharedJSONHasFormatSummaryButNoRawPayload() throws {
        var scan = NinebotScanDiagnostics()
        let id = UUID(), secretLikePayload = Data([0x4e, 0x42] + Array("PRIVATEPAYLOAD".utf8))
        record(&scan, id: id, name: "Own vehicle", manufacturer: secretLikePayload, rssi: 127)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(scan.json.utf8)) as? [String: Any])
        let entry = try XCTUnwrap((object["devices"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["manufacturerPrefix"] as? String, "4E42")
        XCTAssertEqual(entry["manufacturerBytes"] as? Int, secretLikePayload.count)
        XCTAssertNil(entry["rssi"]); XCTAssertNil(entry["manufacturerData"])
        XCTAssertFalse(scan.json.contains("PRIVATEPAYLOAD"))
        XCTAssertFalse(scan.json.contains(secretLikePayload.base64EncodedString()))
    }
    func testEmptyScanAndInvalidTimeDoNotInventDiscovery() {
        var scan = NinebotScanDiagnostics()
        XCTAssertEqual(scan.packetCount, 0); XCTAssertTrue(scan.entries.isEmpty)
        record(&scan, id: UUID(), time: .nan)
        XCTAssertEqual(scan.packetCount, 0); XCTAssertTrue(scan.entries.isEmpty)
        XCTAssertTrue(scan.summary.contains("收到 0 条广播"))
    }
    func testUnsupportedProtocolRemainsBlockedAndSystemNameDoesNotAuthorizePairing() throws {
        var scan = NinebotScanDiagnostics(), evidence = DiscoveryEvidence()
        let id = UUID()
        evidence.merge(manufacturerData: advertisement(4), localName: "Car", isConnectable: true)
        record(&scan, id: id, evidence: evidence)
        XCTAssertEqual(scan.recognizedCount, 1); XCTAssertEqual(scan.eligibleCount, 0)
        XCTAssertTrue(try XCTUnwrap(scan.entries[id]).reason.contains("v4"))
        let second = UUID()
        var missingName = DiscoveryEvidence()
        missingName.merge(manufacturerData: advertisement(), localName: nil, isConnectable: true)
        record(&scan, id: second, name: "Cached system name", evidence: missingName)
        XCTAssertFalse(try XCTUnwrap(scan.entries[second]).eligible)
    }
}
