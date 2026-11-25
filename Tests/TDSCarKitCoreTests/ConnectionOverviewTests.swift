import XCTest
@testable import TDSCarKitCore

final class ConnectionOverviewTests: XCTestCase {
    func testAnAddressWithoutSSIDDoesNotClaimSelectedNetwork() {
        let state = ConnectionOverview(phase: .starting, expectedSSID: "Vehicle", actualSSID: nil,
            hasWiFiAddress: true, hasIdentity: true)
        XCTAssertEqual(state.wifi, "Wi-Fi 地址可用，网络名称未确认")
        XCTAssertFalse(state.wifi.contains("已连接"))
    }
    func testDifferentNetworkNeedsActionEvenWhenIPExists() {
        let state = ConnectionOverview(phase: .idle, expectedSSID: "Vehicle", actualSSID: "Home",
            hasWiFiAddress: true, hasIdentity: true)
        XCTAssertTrue(state.needsNetworkAction)
        XCTAssertTrue(state.wifi.contains("不一致"))
    }
    func testOldSSIDWithoutCurrentAddressCannotClaimConnected() {
        let state = ConnectionOverview(phase: .stopped, expectedSSID: "Vehicle", actualSSID: "Vehicle",
            hasWiFiAddress: false, hasIdentity: true)
        XCTAssertTrue(state.needsNetworkAction)
        XCTAssertFalse(state.wifi.contains("已连接"))
    }
    func testJoiningAndControlConnectionNeverClaimVideo() {
        for phase in [ConnectionOverview.Phase.checkingWiFi, .starting, .controlConnected] {
            let state = ConnectionOverview(phase: phase, expectedSSID: "Vehicle", actualSSID: "Vehicle",
                hasWiFiAddress: true, hasIdentity: true)
            XCTAssertFalse(state.carPlay.contains("已出画"))
        }
    }
    func testFailureAndMissingIdentityOverrideReadyState() {
        let failure = ConnectionOverview(phase: .idle, expectedSSID: "", actualSSID: nil,
            hasWiFiAddress: false, hasIdentity: true, failure: "端口被占用")
        XCTAssertEqual(failure.carPlay, "端口被占用")
        let missing = ConnectionOverview(phase: .idle, expectedSSID: "", actualSSID: nil,
            hasWiFiAddress: false, hasIdentity: false)
        XCTAssertTrue(missing.carPlay.contains("缺少"))
    }
    func testInstrumentTransmissionDoesNotCertifyActualDisplay() {
        XCTAssertTrue(InstrumentChannelPhase.sending.title.contains("待确认"))
        XCTAssertTrue(InstrumentChannelPhase.waitingForPorts.title.contains("占用"))
        for phase in [InstrumentChannelPhase.ready, .responding, .sending] {
            XCTAssertFalse(phase.title.contains("已出画"))
        }
    }
}
