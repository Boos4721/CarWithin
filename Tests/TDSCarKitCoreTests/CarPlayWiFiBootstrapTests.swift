import XCTest
@testable import TDSCarKitCore

final class CarPlayWiFiBootstrapTests: XCTestCase {
    private func request(_ bootstrap: CarPlayWiFiBootstrap) throws -> IAP2Message {
        let message = try AccessoryMessages.startSession(address: "192.168.1.20", port: 7000,
            deviceID: "02:03:04:05:06:07", wifi: bootstrap.wifi)
        return try IAP2Message.parse(message.encoded())
    }

    func testCurrentNetworkOmitsCredentialsEvenWhenFallbackIsSaved() throws {
        let credentials = try AccessoryMessages.WiFi(ssid: "Instrument", password: "saved-password", channel: 44)
        let bootstrap = CarPlayWiFiBootstrap(currentNetworkWithFallback: credentials)
        let message = try request(bootstrap)

        XCTAssertTrue(bootstrap.usesCurrentNetwork)
        XCTAssertNil(message.parameters.first { $0.id == 1 })
        let address = try XCTUnwrap(message.parameters.first { $0.id == 0 })
        XCTAssertEqual(try IAP2Parameter.parse(address.value), [.init(id: 0, value: Data("192.168.1.20\0".utf8))])
        XCTAssertEqual(message.parameters.first { $0.id == 2 }?.value, Data([0, 0, 0x1b, 0x58]))
    }

    func testFallbackRestoresEncryptedNetworkAndRunsOnlyOnce() throws {
        let credentials = try AccessoryMessages.WiFi(ssid: "Instrument", password: "saved-password", channel: 44)
        var bootstrap = CarPlayWiFiBootstrap(currentNetworkWithFallback: credentials)

        XCTAssertTrue(bootstrap.useFallbackCredentials())
        XCTAssertFalse(bootstrap.useFallbackCredentials())
        XCTAssertFalse(bootstrap.usesCurrentNetwork)
        let group = try XCTUnwrap(try request(bootstrap).parameters.first { $0.id == 1 })
        let fields = try IAP2Parameter.parse(group.value)
        XCTAssertEqual(fields.first { $0.id == 0 }?.value, Data("Instrument\0".utf8))
        XCTAssertEqual(fields.first { $0.id == 1 }?.value, Data("saved-password\0".utf8))
        XCTAssertEqual(fields.first { $0.id == 2 }?.value, Data([44]))
        XCTAssertEqual(fields.first { $0.id == 4 }?.value, Data([2]))
    }

    func testUnknownPasswordNeverBecomesAnOpenNetwork() throws {
        var bootstrap = CarPlayWiFiBootstrap(currentNetworkWithFallback: nil)

        XCTAssertNil(bootstrap.availableCredentials)
        XCTAssertFalse(bootstrap.useFallbackCredentials())
        XCTAssertTrue(bootstrap.usesCurrentNetwork)
        XCTAssertNil(try request(bootstrap).parameters.first { $0.id == 1 })
    }

    func testExplicitOpenNetworkRemainsAvailableForFallback() throws {
        let credentials = try AccessoryMessages.WiFi(ssid: "Open Instrument", password: "")
        var bootstrap = CarPlayWiFiBootstrap(currentNetworkWithFallback: credentials)

        XCTAssertTrue(bootstrap.useFallbackCredentials())
        let group = try XCTUnwrap(try request(bootstrap).parameters.first { $0.id == 1 })
        XCTAssertEqual(try IAP2Parameter.parse(group.value).first { $0.id == 4 }?.value, Data([0]))
    }

    func testLegacyCredentialsAreSentImmediatelyWithoutFallback() throws {
        let credentials = try AccessoryMessages.WiFi(ssid: "Instrument", password: "saved-password")
        var bootstrap = CarPlayWiFiBootstrap(credentials: credentials)

        XCTAssertFalse(bootstrap.usesCurrentNetwork)
        XCTAssertFalse(bootstrap.useFallbackCredentials())
        XCTAssertNotNil(try request(bootstrap).parameters.first { $0.id == 1 })
    }
}
