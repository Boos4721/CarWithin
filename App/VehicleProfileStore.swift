import Foundation

/// Passwords remain in the existing SSID Keychain entry; profiles store references.
struct VehicleProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    var output: Int
    var ssid: String
    var channel: UInt8
    var openNetwork: Bool
    var instrumentAddress: String
    var bmsID: UUID?
    var bmsName: String?
    var bmsEnabled: Bool
    var cardFields: [String]
    var cardSize: Int
    var cardPosition: Int
    var autoConnect: Bool
    var currentWiFiExperiment: Bool
    var keepAlive: Bool
    var autoFullscreen: Bool
}

enum VehicleProfileStore {
    private static let key = "vehicleProfiles.v1"
    static var selectedID: UUID? {
        UserDefaults.standard.string(forKey: "selectedVehicleProfile").flatMap(UUID.init(uuidString:))
    }
    static func profiles() -> [VehicleProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([VehicleProfile].self, from: data)) ?? []
    }
    static func save(_ profile: VehicleProfile) throws {
        var values = profiles()
        if let index = values.firstIndex(where: { $0.id == profile.id }) { values[index] = profile }
        else { values.append(profile) }
        UserDefaults.standard.set(try JSONEncoder().encode(values), forKey: key)
        UserDefaults.standard.set(profile.id.uuidString, forKey: "selectedVehicleProfile")
    }
    static func select(_ id: UUID) { UserDefaults.standard.set(id.uuidString, forKey: "selectedVehicleProfile") }
    static func remove(_ id: UUID) throws {
        let values = profiles().filter { $0.id != id }
        UserDefaults.standard.set(try JSONEncoder().encode(values), forKey: key)
        if selectedID == id { UserDefaults.standard.removeObject(forKey: "selectedVehicleProfile") }
    }
}

struct BMSRideRecord: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let vehicleName: String
    let statistics: ANTBMSSessionStatistics
    let completed: Bool
}

enum BMSRideRecordStore {
    private static let key = "bmsRideRecords.v1"
    static func records() -> [BMSRideRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BMSRideRecord].self, from: data)) ?? []
    }
    static func save(_ record: BMSRideRecord) throws {
        var values = records().filter { $0.id != record.id }; values.insert(record, at: 0)
        UserDefaults.standard.set(try JSONEncoder().encode(Array(values.prefix(20))), forKey: key)
    }
    static func remove(_ id: UUID) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(records().filter { $0.id != id }), forKey: key)
    }
}
