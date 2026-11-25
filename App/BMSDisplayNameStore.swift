import Foundation

enum BMSDisplayNameStore {
    private static let key = "bmsDisplayNames.v1"
    static func name(for id: UUID?, fallback: String) -> String {
        guard let id else { return fallback }
        return UserDefaults.standard.string(forKey: key + "." + id.uuidString) ?? fallback
    }
    static func save(_ name: String, for id: UUID) {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let nameKey = key + "." + id.uuidString
        if value.isEmpty { UserDefaults.standard.removeObject(forKey: nameKey) }
        else { UserDefaults.standard.set(value, forKey: nameKey) }
    }
}
