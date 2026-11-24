import Foundation

/// Exercises the persisted pre-build-24 vehicle schema without touching UserDefaults.
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
        precondition(profile.cardBackground == nil)
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
    }
}
