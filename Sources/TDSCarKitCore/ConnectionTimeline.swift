import Foundation

/// Bounded, explicit connection events; never receives credential material.
public struct ConnectionTimeline: Codable {
    public enum Stage: String, Codable {
        case preparing, wifi, accessory, control, video, instrument, stopped, failed
        public var title: String {
            switch self {
            case .preparing: "准备连接"
            case .wifi: "Wi-Fi"
            case .accessory: "配件认证"
            case .control: "CarPlay 控制"
            case .video: "本机视频"
            case .instrument: "仪表通道"
            case .stopped: "已停止"
            case .failed: "连接失败"
            }
        }
    }
    public struct Event: Codable, Equatable {
        public let elapsed: TimeInterval
        public let stage: Stage
        public let detail: String
    }
    public let startedAt: Date
    public let output: String
    public private(set) var events: [Event] = []
    public private(set) var firstVideoSeconds: TimeInterval?
    public private(set) var ended = false
    private let origin: TimeInterval

    public init(output: String, startedAt: Date = Date(), uptime: TimeInterval) {
        self.output = output; self.startedAt = startedAt; origin = uptime
    }

    public mutating func record(_ stage: Stage, detail: String, uptime: TimeInterval) {
        guard !ended else { return }
        let elapsed = max(events.last?.elapsed ?? 0, uptime - origin, 0)
        let bounded = String(detail.prefix(300))
        if let last = events.last, last.stage == stage, last.detail == bounded { return }
        events.append(Event(elapsed: elapsed, stage: stage, detail: bounded))
        if events.count > 64 { events.removeFirst(events.count - 64) }
        if stage == .video, firstVideoSeconds == nil { firstVideoSeconds = elapsed }
        if stage == .stopped || stage == .failed { ended = true }
    }
}
