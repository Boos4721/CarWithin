import Foundation

extension NinebotVehicleConnection {
    private func fixtureChannel(_ item: CBPeripheral) {
        item.state = .connected
        writeCharacteristic = CBCharacteristic(Self.writeID, properties: .writeWithoutResponse)
        notifyCharacteristic = CBCharacteristic(Self.notifyID, properties: .notify)
        beginPrecommunication()
    }
    private func fixturePrecomm(index: UInt8 = 1) {
        handle(VehicleBLEFrame(src: 0x04, dst: 0x3e, command: 0x5b, index: index,
                               payload: Data(repeating: 7, count: 30)))
    }
    @MainActor static func runLifecycleSmoke() {
        func fixture(saved: Bool = false, cached: Bool = true) -> (NinebotVehicleConnection, NinebotVehicle, CBPeripheral) {
            CBCentralManager.registry = [:]
            NinebotVehicleKeyStore.records = [:]
            NinebotVehicleKeyStore.generatedKeys = 0
            let vehicle = NinebotVehicle(id: UUID(), name: "TEST", protocolVersion: 2, serialLength: 14)
            let item = CBPeripheral(id: vehicle.id)
            if cached { CBCentralManager.registry[vehicle.id] = item }
            let suite = "CarWithin.PairingSmoke." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            if saved {
                var garage = NinebotVehicleSelection()
                garage.save(vehicle); garage.select(vehicle.id)
                defaults.set(try! JSONEncoder().encode(garage), forKey: garageKey)
            }
            return (NinebotVehicleConnection(defaults: defaults), vehicle, item)
        }
        do {
            let (client, vehicle, item) = fixture()
            client.begin(.pairing, vehicle: vehicle); client.prepareCentral(); client.reconnectVehicle()
            client.fixtureChannel(item); client.fixturePrecomm(index: 0)
            precondition(client.phase == .needsPairing && NinebotVehicleKeyStore.generatedKeys == 0)
            client.beginPairing(confirmedTarget: client.pairingTarget!)
            precondition(!client.readyForButtonPress && client.confirmationWindow == nil)
            client.handle(VehicleBLEFrame(src: 0x23, dst: 0x3e, command: 0x5c, index: 0))
            precondition(!client.readyForButtonPress)
            client.handle(VehicleBLEFrame(src: 0x04, dst: 0x3e, command: 0x5c, index: 0))
            let window = client.confirmationWindow
            precondition(client.readyForButtonPress && window != nil)
            client.handle(VehicleBLEFrame(src: 0x04, dst: 0x3e, command: 0x5c, index: 0))
            precondition(client.confirmationWindow == window)
            client.handle(VehicleBLEFrame(src: 0x04, dst: 0x3e, command: 0x5c, index: 1))
            precondition(client.phase == .authenticating && !client.readyForButtonPress)
            client.handle(VehicleBLEFrame(src: 0x04, dst: 0x3e, command: 0x5d, index: 1))
            precondition(client.phase == .paired && client.garage.selected == nil)
            precondition(NinebotVehicleKeyStore.records[vehicle.id]?.confirmedKey != nil)
            print("PASS: pairing waits for vehicle readiness, bounds the button window and authenticates before saving")
        }
        do {
            let (client, vehicle, item) = fixture(saved: true)
            client.rePairSelectedVehicle(); client.fixtureChannel(item); client.fixturePrecomm()
            let key = NinebotVehicleKeyStore.records[vehicle.id]?.pendingKey
            let oldTimer = client.retryTask!
            for _ in 0..<8 { client.retryTask?.perform() }
            precondition(client.phase == .reconnecting && client.pairingAuthorizedVehicleID == vehicle.id)
            item.state = .disconnected
            client.centralManager(client.central, didDisconnectPeripheral: item, error: nil)
            client.reconnectTask?.perform()
            client.fixtureChannel(item); client.fixturePrecomm()
            precondition(client.phase == .pairing && NinebotVehicleKeyStore.generatedKeys == 1)
            precondition(NinebotVehicleKeyStore.records[vehicle.id]?.pendingKey == key)
            let count = item.writes.count
            oldTimer.perform()
            precondition(item.writes.count == count)
            client.cancelPairing()
            precondition(NinebotVehicleKeyStore.records[vehicle.id]?.pendingKey == key)
            print("PASS: authorized readiness recovery reuses one write-ahead key and cancellation invalidates old timers")
        }
        do {
            let (client, _, item) = fixture(saved: true)
            client.startProjection(); client.fixtureChannel(item); client.fixturePrecomm()
            precondition(client.phase == .failed && NinebotVehicleKeyStore.generatedKeys == 0)
            print("PASS: projection authentication failure never starts SET_PWD automatically")
        }
        do {
            let (client, _, item) = fixture(saved: true)
            client.rePairSelectedVehicle()
            let oldCentral = client.central!
            let oldDelegate = client.peripheralDelegate!
            client.fixtureChannel(item); client.fixturePrecomm()
            client.fail("fixture timeout", retryable: true)
            client.disconnectFallbackTask?.perform()
            let newCentral = client.central!
            precondition(oldCentral !== newCentral && oldCentral.delegate == nil)
            client.centralManagerDidUpdateState(newCentral)
            precondition(client.reconnectCount == 1)
            client.reconnectTask?.perform()
            client.discover(item)
            precondition(client.phase == .discovering)
            oldCentral.state = .poweredOff
            client.centralManagerDidUpdateState(oldCentral)
            client.centralManager(oldCentral, didDisconnectPeripheral: item, error: nil)
            oldDelegate.peripheral(item, didModifyServices: [CBService(Self.service)])
            precondition(client.phase == .discovering && client.peripheral === item)
            client.finishDisconnect(message: "fixture end")
            print("PASS: missing disconnect callbacks replace the central and isolate old central/peripheral callbacks")
        }
        do {
            let (client, vehicle, item) = fixture(saved: true, cached: false)
            client.rePairSelectedVehicle()
            precondition(client.isScanning && client.attemptVehicle?.id == vehicle.id)
            client.centralManager(client.central, didDiscover: CBPeripheral(id: UUID()), advertisementData: [:], rssi: -40)
            precondition(client.peripheral == nil && client.isScanning)
            client.centralManager(client.central, didDiscover: item, advertisementData: [:], rssi: -40)
            precondition(client.peripheral === item && !client.isScanning)
            for _ in 0..<100 { client.logBLE("fixture state") }
            precondition(client.debugLogs.count == 80)
            client.cancelPairing()
            print("PASS: saved-device scan only connects the selected UUID and diagnostics remain bounded")
        }
    }
}

@main struct NinebotPairingLifecycleSmoke {
    @MainActor static func main() { NinebotVehicleConnection.runLifecycleSmoke() }
}
