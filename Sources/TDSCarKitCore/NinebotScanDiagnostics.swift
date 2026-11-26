import Foundation

/// Scan visibility is independent of pairing eligibility. Never derives identity
/// or authentication parameters from a name, RSSI or a generic UART UUID.
struct NinebotScanDiagnostics: Equatable {
    static let uartService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    struct Entry: Identifiable, Equatable {
        let id: UUID
        var name = "未命名蓝牙设备"
        var rssi: Int?
        var lastSeen: TimeInterval
        var services: [String] = []
        var manufacturerPrefix: String?
        var manufacturerBytes = 0
        var reason = "未收到厂商广播信息"
        var hasAdvertisedName = false
        var hasConnectableAdvertisement = false
        var protocolVersion: UInt8?
        var recognized = false
        var eligible = false
        var systemConnected = false
        var shortID: String { String(id.uuidString.suffix(6)) }
        var hasUART: Bool { services.contains(NinebotScanDiagnostics.uartService) }
    }
    private(set) var entries: [UUID: Entry] = [:]
    private(set) var packetCount = 0
    private(set) var capacityDrops = 0
    let maximumDevices: Int
    init(maximumDevices: Int = 100) { self.maximumDevices = min(100, max(1, maximumDevices)) }

    mutating func observe(id: UUID, name: String?, rssi: Int?, services: [String],
                         manufacturerData: Data?, evidence: DiscoveryEvidence,
                         now: TimeInterval, systemConnected: Bool = false) {
        guard now.isFinite else { return }
        if !systemConnected { packetCount += 1 }
        if entries[id] == nil, entries.count >= maximumDevices {
            guard let oldest = entries.values.filter({ !$0.recognized }).min(by: { $0.lastSeen < $1.lastSeen }) else {
                capacityDrops += 1; return
            }
            entries.removeValue(forKey: oldest.id)
            capacityDrops += 1
        }
        var item = entries[id] ?? Entry(id: id, lastSeen: now)
        item.lastSeen = now
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        }
        if let rssi, (-127 ... -1).contains(rssi) { item.rssi = rssi }
        item.services = Array(Set(item.services + services.filter { $0.utf8.count <= 64 }.map { $0.uppercased() }))
            .sorted().prefix(16).map { $0 }
        item.systemConnected = item.systemConnected || systemConnected
        item.hasAdvertisedName = !evidence.localName.isEmpty
        item.hasConnectableAdvertisement = evidence.hasConnectableAdvertisement
        if let manufacturerData {
            item.manufacturerBytes = manufacturerData.count
            item.manufacturerPrefix = manufacturerData.count >= 2
                ? manufacturerData.prefix(2).map { String(format: "%02X", $0) }.joined() : nil
            do { _ = try Advertisement.parse(manufacturerData: manufacturerData) }
            catch let error as AdvertisementError {
                switch error {
                case .unsupportedManufacturer: item.reason = "其他厂商广播，未确认是九号车辆"
                case .malformed: item.reason = "厂商广播格式不完整或尚未支持"
                case .checksumMismatch: item.reason = "九号厂商广播校验未通过"
                }
            } catch { item.reason = "厂商广播尚未识别" }
        }
        if let advertisement = evidence.advertisement {
            item.protocolVersion = advertisement.protocolVersion
            item.recognized = true
            item.eligible = evidence.isEligible
            if !advertisement.canAttemptLocalAuthentication {
                item.reason = "已识别九号广播，但尚不支持 v\(advertisement.protocolVersion) 握手"
            } else if evidence.localName.isEmpty {
                item.reason = "已识别九号广播，尚缺广播名称"
            } else if !evidence.hasConnectableAdvertisement {
                item.reason = "已识别九号广播，尚未收到可连接标志"
            } else { item.reason = "九号广播已识别，可继续核对车辆" }
        }
        entries[id] = item
    }

    var unrecognized: [Entry] {
        entries.values.filter { !$0.recognized }.sorted {
            if $0.systemConnected != $1.systemConnected { return $0.systemConnected }
            if $0.hasUART != $1.hasUART { return $0.hasUART }
            if $0.rssi != $1.rssi { return ($0.rssi ?? -128) > ($1.rssi ?? -128) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    var recognizedCount: Int { entries.values.filter(\.recognized).count }
    var eligibleCount: Int { entries.values.filter(\.eligible).count }
    var summary: String {
        "收到 \(packetCount) 条广播 · 记录 \(entries.count) 台蓝牙 · 九号已识别 \(recognizedCount) 台 · 可连接 \(eligibleCount) 台"
    }
    /// User-initiated local sharing includes device names and local identifiers,
    /// but no raw manufacturer payload, pairing keys or authentication traffic.
    var json: String {
        let devices: [[String: Any]] = entries.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { item in
            var value: [String: Any] = ["localIdentifier": item.id.uuidString, "name": item.name,
                "services": item.services, "manufacturerBytes": item.manufacturerBytes,
                "recognized": item.recognized, "eligible": item.eligible,
                "systemConnected": item.systemConnected, "reason": item.reason,
                "hasAdvertisedName": item.hasAdvertisedName,
                "hasConnectableAdvertisement": item.hasConnectableAdvertisement]
            if let version = item.protocolVersion { value["protocolVersion"] = Int(version) }
            if let rssi = item.rssi { value["rssi"] = rssi }
            if let prefix = item.manufacturerPrefix { value["manufacturerPrefix"] = prefix }
            return value
        }
        let report: [String: Any] = ["schemaVersion": 1, "broadcastPackets": packetCount,
            "maximumDevices": maximumDevices, "capacityDrops": capacityDrops,
            "summary": summary, "devices": devices]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
