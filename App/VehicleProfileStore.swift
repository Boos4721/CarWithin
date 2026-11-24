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
    /// Absent in build 23 profiles; nil retains the original 86% background.
    var cardBackground: Int? = nil
    /// Optional additions for PR #35; older vehicle profiles keep loading unchanged.
    var zeehoAutomaticAddress: Bool? = nil
    var zeehoFrameRate: Int? = nil
    var zeehoCanvas: Int? = nil
    var zeehoVideoMode: Int? = nil
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
    /// Optional so records saved before build 25 remain readable.
    var vehicleID: UUID? = nil
    var bmsID: UUID? = nil
}

struct BMSRecordFilter {
    enum Period: Int, CaseIterable {
        case all, today, last7Days, last30Days
        var title: String { ["全部时间", "今天", "最近 7 天", "最近 30 天"][rawValue] }
    }
    enum Completion: Int, CaseIterable {
        case all, finished, fragments, recording
        var title: String { ["全部状态", "已结束", "已保存片段", "记录中"][rawValue] }
    }
    var vehicleID: UUID?
    var vehicleName: String?
    var period: Period = .all
    var completion: Completion = .all

    func matches(_ record: BMSRideRecord, now: Date = Date(), calendar: Calendar = .current,
                 activeRecordID: UUID? = nil) -> Bool {
        if let vehicleName {
            if let vehicleID, let recordID = record.vehicleID {
                guard recordID == vehicleID else { return false }
            } else {
                guard record.vehicleName == vehicleName else { return false }
            }
        }
        let active = record.id == activeRecordID
        switch completion {
        case .all: break
        case .finished: guard record.completed && !active else { return false }
        case .fragments: guard !record.completed && !active else { return false }
        case .recording: guard active else { return false }
        }
        if period != .all {
            let days = period == .today ? 0 : period == .last7Days ? 6 : 29
            let startOfToday = calendar.startOfDay(for: now)
            guard let lower = calendar.date(byAdding: .day, value: -days, to: startOfToday),
                  let upper = calendar.date(byAdding: .day, value: 1, to: startOfToday),
                  record.startedAt >= lower, record.startedAt < upper else { return false }
        }
        return true
    }
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
