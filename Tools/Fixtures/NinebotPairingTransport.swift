// Deterministic transport for the production connection state-machine smoke test.
// Crypto and Keychain are substitutes here; their real implementations are covered
// by core cryptographic tests and the device app build respectively.
import Foundation
import Combine

protocol CBCentralManagerDelegate: AnyObject {}
protocol CBPeripheralDelegate: AnyObject {}
enum CBManagerState: Int { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
enum CBPeripheralState { case disconnected, connecting, connected, disconnecting }
enum CBCharacteristicWriteType { case withoutResponse }
struct CBCharacteristicProperties: OptionSet {
    let rawValue: Int
    static let writeWithoutResponse = Self(rawValue: 1)
    static let notify = Self(rawValue: 2)
    static let indicate = Self(rawValue: 4)
}
struct CBUUID: Hashable {
    let uuidString: String
    init(string: String) { uuidString = string }
}
let CBCentralManagerOptionShowPowerAlertKey = "powerAlert"
let CBCentralManagerScanOptionAllowDuplicatesKey = "duplicates"
let CBAdvertisementDataManufacturerDataKey = "manufacturer"
let CBAdvertisementDataLocalNameKey = "name"
let CBAdvertisementDataIsConnectable = "connectable"
let CBAdvertisementDataServiceUUIDsKey = "services"
let CBAdvertisementDataOverflowServiceUUIDsKey = "overflow"
let CBAdvertisementDataServiceDataKey = "serviceData"

@MainActor final class CBCharacteristic {
    let uuid: CBUUID
    var properties: CBCharacteristicProperties
    var isNotifying = true
    var value: Data?
    init(_ uuid: CBUUID, properties: CBCharacteristicProperties) { self.uuid = uuid; self.properties = properties }
}
@MainActor final class CBService {
    let uuid: CBUUID
    var characteristics: [CBCharacteristic]?
    init(_ uuid: CBUUID) { self.uuid = uuid }
}
@MainActor final class CBPeripheral {
    let identifier: UUID
    var name: String? = "Fixture vehicle"
    var state: CBPeripheralState = .disconnected
    weak var delegate: CBPeripheralDelegate?
    var services: [CBService]?
    var canSendWriteWithoutResponse = true
    var writes: [Data] = []
    init(id: UUID) { identifier = id }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 512 }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) { writes.append(data) }
    func discoverServices(_ services: [CBUUID]?) {}
    func discoverCharacteristics(_ characteristics: [CBUUID]?, for service: CBService) {}
    func setNotifyValue(_ value: Bool, for characteristic: CBCharacteristic) { characteristic.isNotifying = value }
}
@MainActor final class CBCentralManager {
    static var registry: [UUID: CBPeripheral] = [:]
    weak var delegate: CBCentralManagerDelegate?
    var state: CBManagerState = .poweredOn
    var isScanning = false
    init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]?) { self.delegate = delegate }
    func scanForPeripherals(withServices: [CBUUID]?, options: [String: Any]?) { isScanning = true }
    func stopScan() { isScanning = false }
    func retrieveConnectedPeripherals(withServices: [CBUUID]) -> [CBPeripheral] { [] }
    func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] { ids.compactMap { Self.registry[$0] } }
    func connect(_ item: CBPeripheral) { item.state = .connected }
    func cancelPeripheralConnection(_ item: CBPeripheral) { item.state = .disconnecting }
}

final class V2Crypto {
    func resetSerial() {}
    func setKey(_ key: Data, _ parameter: Data?) throws {}
    func setAuthParam(_ parameter: Data) throws {}
    func startSerial() {}
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { throw VehicleBLEFrameError.malformed }
}

@MainActor struct NinebotVehicleKeyStore {
    struct Record {
        var confirmedKey: Data?
        var pendingKey: Data?
        var pendingWriteAcknowledged = false
        var authenticationCandidates: [Data] { [pendingKey, confirmedKey].compactMap { $0 } }
    }
    static var records: [UUID: Record] = [:]
    static var generatedKeys = 0
    func load(for id: UUID) throws -> Record { Self.records[id] ?? Record() }
    func remove(for id: UUID) throws { Self.records.removeValue(forKey: id) }
    func prepareCandidate(for id: UUID) throws -> Data {
        var record = try load(for: id)
        if let pending = record.pendingKey { return pending }
        Self.generatedKeys += 1
        let key = Data(repeating: UInt8(Self.generatedKeys), count: 32)
        record.pendingKey = key
        Self.records[id] = record
        return key
    }
    func acknowledgeWrite(_ key: Data, for id: UUID) throws {
        var record = try load(for: id)
        precondition(record.pendingKey == key)
        record.pendingWriteAcknowledged = true
        Self.records[id] = record
    }
    func confirmAuthentication(_ key: Data, for id: UUID) throws {
        var record = try load(for: id)
        precondition(record.authenticationCandidates.contains(key))
        record.confirmedKey = key
        if record.pendingKey == key { record.pendingKey = nil; record.pendingWriteAcknowledged = false }
        Self.records[id] = record
    }
}
