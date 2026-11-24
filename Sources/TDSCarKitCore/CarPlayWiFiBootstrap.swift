/// Selects the wireless information included in a CarPlay start-session request.
/// Reusing an existing network omits the whole wireless group; an unknown password
/// must never be represented as an open network.
public struct CarPlayWiFiBootstrap {
    public private(set) var wifi: AccessoryMessages.WiFi?
    private var fallback: AccessoryMessages.WiFi?

    public var usesCurrentNetwork: Bool { wifi == nil }
    public var availableCredentials: AccessoryMessages.WiFi? { wifi ?? fallback }

    public init(credentials: AccessoryMessages.WiFi) {
        wifi = credentials
        fallback = nil
    }

    public init(currentNetworkWithFallback credentials: AccessoryMessages.WiFi? = nil) {
        wifi = nil
        fallback = credentials
    }

    /// A timeout may switch to genuine credentials once, without changing the
    /// current Wi-Fi association or inventing a password.
    @discardableResult
    public mutating func useFallbackCredentials() -> Bool {
        guard wifi == nil, let fallback else { return false }
        wifi = fallback
        self.fallback = nil
        return true
    }
}
