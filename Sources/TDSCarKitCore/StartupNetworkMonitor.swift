import Foundation

/// A brief Wi-Fi reassociation with the same address must not tear down CarPlay.
/// A changed address must settle before rebuilding listeners and UDP sockets.
public struct StartupNetworkMonitor {
    public enum Update: Equatable {
        case waiting, recovered, restart(String)
    }

    private let initialAddress: String
    private var missingSince: TimeInterval?
    private var candidate: String?
    private var candidateSince: TimeInterval?
    private var needsRestartAfterLoss = false

    public init(address: String) { initialAddress = address }

    public mutating func observe(address: String?, at uptime: TimeInterval) -> Update {
        guard let address else {
            if missingSince == nil { missingSince = uptime }
            candidate = nil; candidateSince = nil
            return .waiting
        }
        var recovered = false
        if let missingSince {
            needsRestartAfterLoss = needsRestartAfterLoss || uptime - missingSince >= 8
            recovered = true
            self.missingSince = nil
        }
        guard address != initialAddress || needsRestartAfterLoss else {
            candidate = nil; candidateSince = nil
            return recovered ? .recovered : .waiting
        }
        if candidate != address {
            candidate = address; candidateSince = uptime
        }
        guard let candidateSince, uptime - candidateSince >= 1 else { return .waiting }
        return .restart(address)
    }
}
