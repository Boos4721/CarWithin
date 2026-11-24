import XCTest
@testable import TDSCarKitCore

final class CarPlayStartupRecoveryTests: XCTestCase {
    func testKnownPasswordBypassesCredentialOmissionExperiment() throws {
        let credentials = try AccessoryMessages.WiFi(ssid: "Instrument", password: "72276986")
        let bootstrap = CarPlayWiFiBootstrap.onConfirmedNetwork(credentials: credentials)
        XCTAssertFalse(bootstrap.usesCurrentNetwork)
        XCTAssertEqual(bootstrap.wifi?.password, credentials.password)
        XCTAssertFalse(CarPlayWiFiBootstrap.onConfirmedNetwork(credentials:
            try AccessoryMessages.WiFi(ssid: "Open Instrument", password: "")).usesCurrentNetwork)
        XCTAssertTrue(CarPlayWiFiBootstrap.onConfirmedNetwork(credentials: nil).usesCurrentNetwork)
    }

    func testHandshakeAndControlDeadlinesCannotBeExtendedByRetries() {
        var deadline = CarPlayStartupDeadline(startedAt: 100)
        XCTAssertNil(deadline.failure(at: 119))
        XCTAssertEqual(deadline.failure(at: 120), .accessoryHandshake)
        deadline.didRequestSession()
        XCTAssertNil(deadline.failure(at: 144))
        deadline.didRequestSession()
        XCTAssertEqual(deadline.failure(at: 145), .controlConnection)
    }

    func testControlConnectionWithoutVideoStillTimesOutDespiteFeedback() {
        var deadline = CarPlayStartupDeadline(startedAt: 100)
        deadline.didRequestSession()
        deadline.didReceiveControlRequest(at: 110)
        XCTAssertNil(deadline.failure(at: 139))
        deadline.didReceiveControlRequest(at: 139)
        XCTAssertEqual(deadline.failure(at: 140), .firstVideo)
    }

    func testVideoCancelsAllStartupDeadlines() {
        var deadline = CarPlayStartupDeadline(startedAt: 100)
        deadline.didRequestSession()
        deadline.didReceiveControlRequest(at: 110)
        deadline.didReceiveVideo()
        XCTAssertNil(deadline.failure(at: 10_000))
    }

    func testBriefAddressLossAndRecoveryDoesNotRestartCarPlay() {
        var monitor = StartupNetworkMonitor(address: "192.168.1.2")
        XCTAssertEqual(monitor.observe(address: "192.168.1.2", at: 100), .waiting)
        XCTAssertEqual(monitor.observe(address: nil, at: 101), .waiting)
        XCTAssertEqual(monitor.observe(address: "192.168.1.2", at: 102), .recovered)
        XCTAssertEqual(monitor.observe(address: "192.168.1.2", at: 104), .waiting)
    }

    func testAddressChangeMustSettleAndCanReturnToOriginalAddress() {
        var monitor = StartupNetworkMonitor(address: "192.168.1.2")
        XCTAssertEqual(monitor.observe(address: "192.168.1.3", at: 100), .waiting)
        XCTAssertEqual(monitor.observe(address: "192.168.1.2", at: 100.5), .waiting)
        XCTAssertEqual(monitor.observe(address: "192.168.1.3", at: 101), .waiting)
        XCTAssertEqual(monitor.observe(address: "192.168.1.3", at: 101.5), .waiting)
        XCTAssertEqual(monitor.observe(address: "192.168.1.3", at: 102), .restart("192.168.1.3"))
    }

    func testLongAddressLossRequiresRestartEvenWithSameAddress() {
        var monitor = StartupNetworkMonitor(address: "192.168.1.2")
        XCTAssertEqual(monitor.observe(address: nil, at: 100), .waiting)
        XCTAssertEqual(monitor.observe(address: "192.168.1.2", at: 108), .waiting)
        XCTAssertEqual(monitor.observe(address: "192.168.1.2", at: 109), .restart("192.168.1.2"))
    }
}
