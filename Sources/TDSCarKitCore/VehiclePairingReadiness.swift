import Foundation

/// Readiness is established by the vehicle's reply, never by a fixed UI delay.
struct VehiclePairingReadiness {
    let startedAt: TimeInterval
    private(set) var requestsSent = 0
    private(set) var readyAt: TimeInterval?

    mutating func didSendRequest() { requestsSent += 1 }

    mutating func acceptReady(_ frame: VehicleBLEFrame, at now: TimeInterval) -> Bool {
        guard readyAt == nil, now.isFinite, now >= startedAt,
              frame.src == 0x04, frame.dst == 0x3e, frame.command == 0x5c,
              frame.index == 0, frame.payload.isEmpty else { return false }
        readyAt = now
        return true
    }

    var confirmationWindow: NinebotPairingWindow? {
        readyAt.map { NinebotPairingWindow(startedAt: $0, duration: 60) }
    }

    var needsReadinessRecovery: Bool { readyAt == nil && requestsSent >= 8 }

    func hasExpired(at now: TimeInterval) -> Bool {
        guard now.isFinite, startedAt.isFinite, now >= startedAt else { return true }
        if let window = confirmationWindow { return window.remaining(at: now) == 0 }
        return now - startedAt >= 20
    }
}

enum VehiclePrecommunication {
    /// Prefer an explicit, valid advertisement length; infer only when absent.
    /// Truncated replies and unbounded remainders must not reach key derivation.
    static func serialLength(payloadCount: Int, advertisedLength: Int?) -> Int? {
        let remaining = payloadCount - 16
        if let advertisedLength {
            guard (1...64).contains(advertisedLength), remaining >= advertisedLength,
                  remaining <= 64 else { return nil }
            return advertisedLength
        }
        return (1...64).contains(remaining) ? remaining : nil
    }
}
