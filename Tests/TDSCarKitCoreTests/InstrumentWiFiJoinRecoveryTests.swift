import XCTest
@testable import TDSCarKitCore

final class InstrumentWiFiJoinRecoveryTests: XCTestCase {
    func testStableExactSSIDAndAddressAreRequired() {
        var probe = InstrumentWiFiJoinReadiness(selectedSSID: "DIRECT-Test")
        XCTAssertFalse(probe.observe(ssid: "DIRECT-Test", address: "192.168.1.5"))
        XCTAssertTrue(probe.observe(ssid: "DIRECT-Test", address: "192.168.1.5"))
    }
    func testIPAddressDoesNotIdentifyAnInstrumentNetwork() {
        var probe = InstrumentWiFiJoinReadiness(selectedSSID: "DIRECT-Test")
        for ssid in [nil, "Home", "direct-test", "DIRECT-Test "] as [String?] {
            XCTAssertFalse(probe.observe(ssid: ssid, address: "192.168.1.5"))
            XCTAssertFalse(probe.observe(ssid: ssid, address: "192.168.1.5"))
        }
    }
    func testTransientMissingSSIDOrChangingAddressResetsStability() {
        var probe = InstrumentWiFiJoinReadiness(selectedSSID: "A")
        XCTAssertFalse(probe.observe(ssid: "A", address: "192.168.1.5"))
        XCTAssertFalse(probe.observe(ssid: nil, address: "192.168.1.5"))
        XCTAssertFalse(probe.observe(ssid: "A", address: "192.168.1.5"))
        XCTAssertFalse(probe.observe(ssid: "A", address: "192.168.1.6"))
        XCTAssertTrue(probe.observe(ssid: "A", address: "192.168.1.6"))
    }
    func testUnavailableAndUnusableAddressesCannotResumeCarPlay() {
        var probe = InstrumentWiFiJoinReadiness(selectedSSID: "A")
        for address in [nil, "", "169.254.1.2", "0.0.0.0", "127.0.0.1", "224.1.2.3", "255.255.255.255", "256.1.2.3", "192.168.1", "192.168.1.2.3", "::1"] as [String?] {
            XCTAssertFalse(probe.observe(ssid: "A", address: address))
            XCTAssertFalse(probe.observe(ssid: "A", address: address))
        }
        var empty = InstrumentWiFiJoinReadiness(selectedSSID: "")
        XCTAssertFalse(empty.observe(ssid: "", address: "192.168.1.5"))
    }
    func testOrdinaryInternalOrPendingErrorsHaveOnlyTwoRetries() {
        XCTAssertTrue(InstrumentWiFiJoinRecovery.shouldRetry(.transient, attempt: 0, preparingVehicleHotspot: false))
        XCTAssertTrue(InstrumentWiFiJoinRecovery.shouldRetry(.transient, attempt: 1, preparingVehicleHotspot: false))
        for attempt in [-1, 2, 3, 100] {
            XCTAssertFalse(InstrumentWiFiJoinRecovery.shouldRetry(.transient, attempt: attempt, preparingVehicleHotspot: false))
        }
    }
    func testVehiclePreparationRemainsBoundedAndDenialNeverRetries() {
        XCTAssertTrue(InstrumentWiFiJoinRecovery.shouldRetry(.transient, attempt: 4, preparingVehicleHotspot: true))
        XCTAssertFalse(InstrumentWiFiJoinRecovery.shouldRetry(.transient, attempt: 5, preparingVehicleHotspot: true))
        for failure in [InstrumentWiFiJoinRecovery.Failure.userDenied, .other] {
            for preparing in [true, false] {
                XCTAssertFalse(InstrumentWiFiJoinRecovery.shouldRetry(failure, attempt: 0, preparingVehicleHotspot: preparing))
            }
        }
    }
}
