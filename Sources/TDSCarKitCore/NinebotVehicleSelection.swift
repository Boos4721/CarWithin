import Foundation

struct NinebotVehicle: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let protocolVersion: UInt8
    let serialLength: Int?
    var displayName: String? = nil
    var title: String { displayName ?? name }
}

/// Only confirmed vehicles are listed. Pairing a new vehicle leaves the current
/// selection in place until the user picks a different one.
struct NinebotVehicleSelection: Codable, Equatable {
    private(set) var vehicles: [NinebotVehicle] = []
    private(set) var selectedID: UUID?

    var selected: NinebotVehicle? { vehicles.first { $0.id == selectedID } }

    mutating func save(_ vehicle: NinebotVehicle) {
        if let index = vehicles.firstIndex(where: { $0.id == vehicle.id }) {
            var updated = vehicle
            updated.displayName = vehicles[index].displayName
            vehicles[index] = updated
        } else {
            vehicles.append(vehicle)
        }
    }

    mutating func rename(_ id: UUID, to name: String) {
        guard let index = vehicles.firstIndex(where: { $0.id == id }) else { return }
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        vehicles[index].displayName = value.isEmpty ? nil : value
    }

    mutating func select(_ id: UUID?) {
        guard id == nil || vehicles.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// A missing pairing in a saved preset must not leave another vehicle selected.
    mutating func restore(_ id: UUID?) {
        selectedID = id.flatMap { candidate in vehicles.contains(where: { $0.id == candidate }) ? candidate : nil }
    }

    mutating func remove(_ id: UUID) {
        vehicles.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }
}
