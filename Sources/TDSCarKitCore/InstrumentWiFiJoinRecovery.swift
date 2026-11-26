import Foundation

/// Recovery never treats an IP address alone as evidence of the selected network.
public struct InstrumentWiFiJoinReadiness {
    private let selectedSSID: String
    private var previousAddress: String?
    public init(selectedSSID: String) { self.selectedSSID = selectedSSID }

    /// Call at spaced observations. Unknown/different SSIDs and unusable addresses break stability.
    public mutating func observe(ssid: String?, address: String?) -> Bool {
        guard !selectedSSID.isEmpty, ssid == selectedSSID, let address, Self.isUsable(address) else {
            previousAddress = nil
            return false
        }
        let ready = previousAddress == address
        previousAddress = address
        return ready
    }

    private static func isUsable(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt8(part)
        }
        guard bytes.count == 4 else { return false }
        return bytes[0] != 0 && bytes[0] != 127 && bytes[0] < 224 &&
            !(bytes[0] == 169 && bytes[1] == 254) && address != "255.255.255.255"
    }
}

public enum InstrumentWiFiJoinRecovery {
    public enum Failure { case transient, userDenied, other }
    /// Attempt zero is the initial request; cap retries even while BLE prepares a hotspot.
    public static func shouldRetry(_ failure: Failure, attempt: Int, preparingVehicleHotspot: Bool) -> Bool {
        guard failure == .transient, attempt >= 0 else { return false }
        return attempt < (preparingVehicleHotspot ? 5 : 2)
    }
}
