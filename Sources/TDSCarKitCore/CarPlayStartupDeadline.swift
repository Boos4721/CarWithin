import Foundation

/// Monotonic deadlines that continue through control negotiation until video arrives.
/// Duplicate session requests and RTSP keepalives must not extend these deadlines.
public struct CarPlayStartupDeadline {
    public enum Failure: Equatable {
        case accessoryHandshake, controlConnection, firstVideo
    }

    private let startedAt: TimeInterval
    private var requested = false
    private var firstControlRequestAt: TimeInterval?
    private var receivedVideo = false

    public init(startedAt: TimeInterval) { self.startedAt = startedAt }
    public mutating func didRequestSession() { requested = true }
    public mutating func didReceiveControlRequest(at uptime: TimeInterval) {
        if firstControlRequestAt == nil { firstControlRequestAt = uptime }
    }
    public mutating func didReceiveVideo() { receivedVideo = true }

    public func failure(at uptime: TimeInterval) -> Failure? {
        guard !receivedVideo else { return nil }
        if let firstControlRequestAt {
            return uptime - firstControlRequestAt >= 30 ? .firstVideo : nil
        }
        if !requested, uptime - startedAt >= 20 { return .accessoryHandshake }
        return uptime - startedAt >= 45 ? .controlConnection : nil
    }
}
