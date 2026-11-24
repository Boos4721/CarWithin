import Foundation

public struct ANTBMSSessionStatistics: Codable, Equatable {
    public struct Point: Codable, Equatable {
        public let elapsed: TimeInterval
        public let voltage: Double
    }
    public private(set) var sampleCount = 0
    public private(set) var firstCharge: Int?
    public private(set) var lastCharge: Int?
    public private(set) var minimumVoltage: Double?
    public private(set) var maximumVoltage: Double?
    public private(set) var peakAbsoluteCurrent = 0.0
    public private(set) var peakAbsolutePower = 0
    public private(set) var maximumTemperature: Double?
    public private(set) var maximumCellDelta: Double?
    public private(set) var sampledSeconds: TimeInterval = 0
    public private(set) var points: [Point] = []
    private var firstUptime: TimeInterval?
    private var lastUptime: TimeInterval?

    public init() {}

    /// Duplicate callbacks, stale frames and clock reversal cannot add samples.
    @discardableResult
    public mutating func append(_ sample: ANTBMSSample, now: TimeInterval) -> Bool {
        guard sample.isFresh(at: now), lastUptime.map({ sample.uptime > $0 }) ?? true else { return false }
        if let lastUptime, sample.uptime - lastUptime <= 5 { sampledSeconds += sample.uptime - lastUptime }
        if firstUptime == nil { firstUptime = sample.uptime }
        lastUptime = sample.uptime
        let reading = sample.reading
        sampleCount += 1
        if firstCharge == nil { firstCharge = reading.stateOfCharge }
        lastCharge = reading.stateOfCharge
        minimumVoltage = min(minimumVoltage ?? reading.voltage, reading.voltage)
        maximumVoltage = max(maximumVoltage ?? reading.voltage, reading.voltage)
        peakAbsoluteCurrent = max(peakAbsoluteCurrent, abs(reading.current))
        peakAbsolutePower = max(peakAbsolutePower, abs(reading.power))
        if let temperature = reading.maximumTemperature {
            maximumTemperature = max(maximumTemperature ?? temperature, temperature)
        }
        if let delta = reading.cellDelta { maximumCellDelta = max(maximumCellDelta ?? delta, delta) }
        let elapsed = sample.uptime - (firstUptime ?? sample.uptime)
        if points.last.map({ elapsed - $0.elapsed >= 5 }) ?? true {
            points.append(Point(elapsed: elapsed, voltage: reading.voltage))
            if points.count > 120 { points.removeFirst(points.count - 120) }
        }
        return true
    }
}
