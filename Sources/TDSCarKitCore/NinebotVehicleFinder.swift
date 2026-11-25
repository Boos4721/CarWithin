import Foundation

/// Two user-labelled observations offer candidates only; broadcast changes do not prove ownership.
struct NinebotVehicleFinder: Equatable {
    enum Stage: Equatable { case idle, prepareOff, scanningOff, prepareOn, scanningOn, results }
    private(set) var stage: Stage = .idle
    private(set) var before: Set<UUID> = []
    private(set) var after: Set<UUID> = []
    var suggestions: Set<UUID> { stage == .results ? after.subtracting(before) : [] }
    mutating func begin() { before = []; after = []; stage = .prepareOff }
    @discardableResult mutating func startRound() -> Bool {
        if stage == .prepareOff { stage = .scanningOff; return true }
        if stage == .prepareOn { stage = .scanningOn; return true }
        return false
    }
    mutating func completeRound(ids: Set<UUID>) {
        if stage == .scanningOff { before = ids; stage = .prepareOn }
        else if stage == .scanningOn { after = ids; stage = .results }
    }
    mutating func cancel() { self = Self() }
}

/// An owner-confirmation dialog is valid for exactly one prepared BLE attempt.
struct NinebotPairingTarget: Equatable {
    let id: UUID
    let bluetoothName: String
    let epoch: UInt64
}
