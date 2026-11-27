import Foundation

/// Checks old schemas and five-inch migration; defaults checks use a temporary suite.
@main
enum ExperienceStoreSmoke {
    static func main() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "name": "旧版五寸配置", "output": 4,
            "ssid": "Instrument", "channel": 36, "openNetwork": false,
            "instrumentAddress": "192.168.1.1", "bmsEnabled": false,
            "cardFields": ["charge", "voltage", "cellDelta"], "cardSize": 1, "cardPosition": 1,
            "autoConnect": false, "currentWiFiExperiment": false,
            "keepAlive": true, "autoFullscreen": false
        ]
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        var profile = try decoder.decode(VehicleProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(profile.cardBackground == nil && profile.cardMode == nil)
        precondition(profile.ninebotVehicleID == nil && profile.bmsFamily == nil)
        precondition(profile.output == 4 && profile.zeehoAutomaticAddress == nil && profile.zeehoFrameRate == nil
            && profile.zeehoCanvas == nil && profile.zeehoVideoMode == nil)
        precondition(ANTBMSCardConfiguration(positionRawValue: profile.cardPosition,
            backgroundRawValue: profile.cardBackground).position == .bottomRight)
        precondition(ANTBMSCardConfiguration(backgroundRawValue: profile.cardBackground).background == .standard)
        profile.cardFields = ["cellDelta", "charge", "voltage"]
        profile.cardPosition = 3; profile.cardBackground = 0
        let data = try encoder.encode(profile)
        let restored = try decoder.decode(VehicleProfile.self, from: data)
        precondition(restored.cardFields == profile.cardFields && restored.cardPosition == 3 && restored.cardBackground == 0)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(json["password"] == nil)
        print("Vehicle profile migration: legacy schema and new card preferences passed")
        var paired = profile
        paired.ninebotVehicleID = UUID()
        paired.bmsFamily = "jikong"
        paired.cardMode = ANTBMSCardConfiguration.Mode.automatic.rawValue
        let pairedRoundTrip = try decoder.decode(VehicleProfile.self, from: encoder.encode(paired))
        precondition(pairedRoundTrip.ninebotVehicleID == paired.ninebotVehicleID && pairedRoundTrip.bmsFamily == "jikong" && pairedRoundTrip.cardMode == 0)
        precondition(pairedRoundTrip.ssid == profile.ssid && pairedRoundTrip.bmsID == profile.bmsID)
        let pairedJSON = try JSONSerialization.jsonObject(with: encoder.encode(paired)) as! [String: Any]
        precondition(pairedJSON["key"] == nil && pairedJSON["password"] == nil)
        print("Ninebot vehicle profiles: optional BLE pairing reference and legacy decoding passed")
        var zeeho = profile
        zeeho.output = 8; zeeho.instrumentAddress = "192.168.2.1"
        zeeho.zeehoAutomaticAddress = false; zeeho.zeehoFrameRate = 60
        zeeho.zeehoCanvas = 0; zeeho.zeehoVideoMode = 1
        let restoredZeeho = try decoder.decode(VehicleProfile.self, from: encoder.encode(zeeho))
        precondition(restoredZeeho.output == 8 && restoredZeeho.instrumentAddress == "192.168.2.1")
        precondition(restoredZeeho.zeehoAutomaticAddress == false && restoredZeeho.zeehoFrameRate == 60
            && restoredZeeho.zeehoCanvas == 0 && restoredZeeho.zeehoVideoMode == 1)
        precondition(profile.output == 4 && profile.zeehoAutomaticAddress == nil)
        var ae2 = profile
        ae2.output = 9; ae2.instrumentAddress = "192.168.3.1"; ae2.zeehoAutomaticAddress = false
        let restoredAE2 = try decoder.decode(VehicleProfile.self, from: encoder.encode(ae2))
        precondition(restoredAE2.output == 9 && restoredAE2.instrumentAddress == "192.168.3.1"
            && restoredAE2.zeehoAutomaticAddress == false && restoredAE2.zeehoFrameRate == nil)
        let migratedSE = restoredZeeho.migratedZeehoFive, migratedAE = restoredAE2.migratedZeehoFive
        precondition(migratedSE.output == 8 && migratedSE.zeehoFiveVariant == 0 && migratedSE.zeehoFrameRate == 60
            && migratedSE.zeehoCanvas == 0 && migratedSE.zeehoVideoMode == 1 && migratedSE.instrumentAddress == "192.168.2.1")
        precondition(migratedAE.output == 8 && migratedAE.zeehoFiveVariant == 1 && migratedAE.zeehoAutomaticAddress == false
            && migratedAE.instrumentAddress == "192.168.3.1" && migratedAE.id == restoredAE2.id)
        let migratedRoundTrip = try decoder.decode(VehicleProfile.self, from: encoder.encode(migratedAE)).migratedZeehoFive
        precondition(migratedRoundTrip.output == 8 && migratedRoundTrip.zeehoFiveVariant == 1)
        precondition(profile.migratedZeehoFive.output == 4 && profile.migratedZeehoFive.zeehoFiveVariant == nil)
        for output in 0...7 {
            var existing = profile; existing.output = output
            precondition(existing.migratedZeehoFive.output == output && existing.migratedZeehoFive.ssid == profile.ssid)
        }
        let suite = "CarWithin.ZeehoFiveSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(9, forKey: "headUnitOutputV2")
        defaults.set("192.168.2.1", forKey: "zeehoSEPlusAddress")
        defaults.set("192.168.3.1", forKey: "zeehoAE2Address")
        defaults.set(false, forKey: "zeehoAE2AutomaticAddress")
        defaults.set(60, forKey: "zeehoSEPlusFrameRate")
        defaults.set("Instrument", forKey: "selectedWiFiPreset")
        ZeehoFivePreferences.migrate(defaults); ZeehoFivePreferences.migrate(defaults)
        precondition(defaults.integer(forKey: "headUnitOutputV2") == 8 && defaults.integer(forKey: "zeehoFiveVariant") == 1)
        precondition(defaults.string(forKey: "zeehoSEPlusAddress") == "192.168.2.1"
            && defaults.string(forKey: "zeehoAE2Address") == "192.168.3.1"
            && !defaults.bool(forKey: "zeehoAE2AutomaticAddress") && defaults.integer(forKey: "zeehoSEPlusFrameRate") == 60
            && defaults.string(forKey: "selectedWiFiPreset") == "Instrument")
        defaults.removeObject(forKey: "zeehoFiveVariant")
        ZeehoFivePreferences.migrate(defaults)
        precondition(defaults.integer(forKey: "zeehoFiveVariant") == 0)
        defaults.set(1, forKey: "zeehoFiveVariant")
        ZeehoFivePreferences.migrate(defaults)
        precondition(defaults.integer(forKey: "zeehoFiveVariant") == 1)
        for output in 0...7 {
            defaults.set(output, forKey: "headUnitOutputV2")
            ZeehoFivePreferences.migrate(defaults)
            precondition(defaults.integer(forKey: "headUnitOutputV2") == output)
        }
        for output in 10...27 {
            var cfmoto = profile; cfmoto.output = output; cfmoto.instrumentAddress = "192.168.0.1"
            let restored = try decoder.decode(VehicleProfile.self, from: encoder.encode(cfmoto)).migratedZeehoFive
            precondition(restored.output == output && restored.instrumentAddress == "192.168.0.1")
            precondition(restored.bmsID == cfmoto.bmsID && restored.cardFields == cfmoto.cardFields)
        }
        print("ZEEHO profiles: unified five-inch migration, subtype, separate addresses/settings, stable IDs 0-7 and idempotent defaults migration passed")

        let now = ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let vehicleID = UUID(), otherID = UUID(), activeID = UUID()
        func record(_ name: String = "我的车", vehicle: UUID? = nil, offset: TimeInterval = 0,
                    completed: Bool = true, id: UUID = UUID()) -> BMSRideRecord {
            BMSRideRecord(id: id, startedAt: now.addingTimeInterval(offset), endedAt: now,
                vehicleName: name, statistics: ANTBMSSessionStatistics(), completed: completed, vehicleID: vehicle)
        }
        var filter = BMSRecordFilter(vehicleID: vehicleID, vehicleName: "改名后的车")
        precondition(filter.matches(record("原车名", vehicle: vehicleID), now: now, calendar: calendar))
        precondition(!filter.matches(record("改名后的车", vehicle: otherID), now: now, calendar: calendar))
        precondition(filter.matches(record("改名后的车"), now: now, calendar: calendar))
        precondition(!filter.matches(record("其他旧车"), now: now, calendar: calendar))
        filter = BMSRecordFilter(period: .today)
        precondition(filter.matches(record(offset: -3600), now: now, calendar: calendar))
        precondition(!filter.matches(record(offset: -24 * 3600), now: now, calendar: calendar))
        precondition(!filter.matches(record(offset: 24 * 3600), now: now, calendar: calendar))
        filter.period = .last7Days
        precondition(filter.matches(record(offset: -6 * 86400), now: now, calendar: calendar))
        precondition(!filter.matches(record(offset: -7 * 86400), now: now, calendar: calendar))
        filter.period = .last30Days
        precondition(filter.matches(record(offset: -29 * 86400), now: now, calendar: calendar))
        precondition(!filter.matches(record(offset: -30 * 86400), now: now, calendar: calendar))
        filter = BMSRecordFilter(completion: .fragments)
        let active = record(completed: false, id: activeID)
        precondition(!filter.matches(active, activeRecordID: activeID))
        precondition(filter.matches(record(completed: false), activeRecordID: activeID))
        filter.completion = .recording
        precondition(filter.matches(active, activeRecordID: activeID))
        precondition(!filter.matches(record(completed: false), activeRecordID: activeID))
        filter.completion = .finished
        precondition(filter.matches(record(), activeRecordID: activeID))
        precondition(!filter.matches(active, activeRecordID: activeID))
        var legacyRecord = try JSONSerialization.jsonObject(with: encoder.encode(record())) as! [String: Any]
        legacyRecord.removeValue(forKey: "vehicleID"); legacyRecord.removeValue(forKey: "bmsID")
        let restoredRecord = try decoder.decode(BMSRideRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyRecord))
        precondition(restoredRecord.vehicleID == nil && restoredRecord.bmsID == nil)
        let newRecord = record(vehicle: vehicleID)
        let restoredNew = try decoder.decode(BMSRideRecord.self, from: encoder.encode(newRecord))
        precondition(restoredNew.vehicleID == vehicleID)
        print("BMS history: vehicle identity, legacy schema, local date boundaries and recording filters passed")
    }
}
