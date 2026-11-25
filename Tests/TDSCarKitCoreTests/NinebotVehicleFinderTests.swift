import Foundation
import XCTest
@testable import TDSCarKitCore

final class NinebotVehicleFinderTests: XCTestCase {
    func testOnlySecondRoundNewIDsBecomeSuggestions() {
        let nearby = UUID(), vehicle = UUID()
        var finder = NinebotVehicleFinder(); finder.begin()
        XCTAssertEqual(finder.stage, .prepareOff)
        XCTAssertTrue(finder.startRound())
        finder.completeRound(ids: [nearby])
        XCTAssertEqual(finder.stage, .prepareOn); XCTAssertTrue(finder.suggestions.isEmpty)
        XCTAssertTrue(finder.startRound()); finder.completeRound(ids: [nearby, vehicle])
        XCTAssertEqual(finder.stage, .results); XCTAssertEqual(finder.suggestions, [vehicle])
    }
    func testAlwaysAdvertisingVehicleDoesNotBecomeFalseSuggestion() {
        let vehicle = UUID()
        var finder = NinebotVehicleFinder(); finder.begin(); _ = finder.startRound()
        finder.completeRound(ids: [vehicle]); _ = finder.startRound(); finder.completeRound(ids: [vehicle])
        XCTAssertTrue(finder.suggestions.isEmpty)
    }
    func testMultipleCandidatesArePreservedWithoutChoosingStrongest() {
        let first = UUID(), second = UUID()
        var finder = NinebotVehicleFinder(); finder.begin(); _ = finder.startRound()
        finder.completeRound(ids: []); _ = finder.startRound(); finder.completeRound(ids: [first, second])
        XCTAssertEqual(finder.suggestions, [first, second])
    }
    func testOutOfOrderCompletionsAndDuplicateStartsDoNotAdvanceGuide() {
        var finder = NinebotVehicleFinder()
        finder.completeRound(ids: [UUID()]); XCTAssertEqual(finder.stage, .idle)
        XCTAssertFalse(finder.startRound()); finder.begin(); finder.completeRound(ids: [])
        XCTAssertEqual(finder.stage, .prepareOff)
        XCTAssertTrue(finder.startRound()); XCTAssertFalse(finder.startRound())
        XCTAssertEqual(finder.stage, .scanningOff)
    }
    func testCancelAndRestartClearEarlierEvidence() {
        var finder = NinebotVehicleFinder(); finder.begin(); _ = finder.startRound()
        finder.completeRound(ids: [UUID()]); finder.cancel()
        XCTAssertEqual(finder.stage, .idle); XCTAssertTrue(finder.before.isEmpty)
        finder.begin(); _ = finder.startRound(); finder.completeRound(ids: [])
        _ = finder.startRound(); finder.completeRound(ids: [UUID()]); XCTAssertFalse(finder.suggestions.isEmpty)
        finder.begin(); XCTAssertTrue(finder.suggestions.isEmpty); XCTAssertTrue(finder.after.isEmpty)
    }
    func testConfirmationTokenChangesWithVehicleNameAndAttempt() {
        let id = UUID(), target = NinebotPairingTarget(id: id, bluetoothName: "Ninebot", epoch: 1)
        XCTAssertEqual(target, NinebotPairingTarget(id: id, bluetoothName: "Ninebot", epoch: 1))
        XCTAssertNotEqual(target, NinebotPairingTarget(id: id, bluetoothName: "Ninebot", epoch: 2))
        XCTAssertNotEqual(target, NinebotPairingTarget(id: UUID(), bluetoothName: "Ninebot", epoch: 1))
        XCTAssertNotEqual(target, NinebotPairingTarget(id: id, bluetoothName: "Changed", epoch: 1))
    }
    func testRenamePreservesOriginalAuthenticationNameAndSelection() throws {
        let vehicle = NinebotVehicle(id: UUID(), name: "OriginalBluetooth", protocolVersion: 2, serialLength: 14)
        var garage = NinebotVehicleSelection(); garage.save(vehicle); garage.select(vehicle.id)
        garage.rename(vehicle.id, to: "  我的通勤车  ")
        let restored = try JSONDecoder().decode(NinebotVehicleSelection.self, from: JSONEncoder().encode(garage))
        XCTAssertEqual(restored.selected?.title, "我的通勤车")
        XCTAssertEqual(restored.selected?.name, "OriginalBluetooth")
        XCTAssertEqual(restored.selectedID, vehicle.id)
        garage.rename(vehicle.id, to: " \n ")
        XCTAssertNil(garage.selected?.displayName); XCTAssertEqual(garage.selected?.title, vehicle.name)
    }
    func testLegacyVehicleWithoutAliasDecodesAndRePairPreservesAlias() throws {
        let vehicle = NinebotVehicle(id: UUID(), name: "Original", protocolVersion: 2, serialLength: 14)
        let data = try JSONEncoder().encode(vehicle)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["displayName"])
        let legacy = try JSONDecoder().decode(NinebotVehicle.self, from: data)
        XCTAssertEqual(legacy.title, "Original")
        var garage = NinebotVehicleSelection(); garage.save(legacy); garage.rename(legacy.id, to: "通勤")
        garage.save(NinebotVehicle(id: legacy.id, name: "NewBluetooth", protocolVersion: 3, serialLength: 16))
        XCTAssertEqual(garage.vehicles.first?.title, "通勤")
        XCTAssertEqual(garage.vehicles.first?.name, "NewBluetooth")
    }
    func testUnknownVehicleRenameAndLongNamesCannotChangeOtherVehicles() {
        let vehicle = NinebotVehicle(id: UUID(), name: "Ninebot", protocolVersion: 2, serialLength: nil)
        var garage = NinebotVehicleSelection(); garage.save(vehicle)
        garage.rename(UUID(), to: "Wrong"); XCTAssertNil(garage.vehicles[0].displayName)
        garage.rename(vehicle.id, to: String(repeating: "车", count: 80))
        XCTAssertEqual(garage.vehicles[0].displayName?.count, 40)
        XCTAssertEqual(garage.vehicles[0].name, "Ninebot")
    }
}
