import Foundation

/// Shared card content and scale for the phone and instrument video.
public struct ANTBMSCardConfiguration: Equatable {
    public enum Field: String, CaseIterable {
        case charge, voltage, temperature, current, power, cellDelta

        public var title: String {
            switch self {
            case .charge: "电量"
            case .voltage: "总压"
            case .temperature: "最高温度"
            case .current: "电流"
            case .power: "功率"
            case .cellDelta: "单体压差"
            }
        }

        fileprivate func text(_ reading: ANTBMSReading) -> String {
            switch self {
            case .charge: return "\(reading.stateOfCharge)%"
            case .voltage: return String(format: "%.2fV", reading.voltage)
            case .temperature: return reading.maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--°C"
            case .current: return String(format: "%+.1fA", reading.current)
            case .power: return "\(reading.power)W"
            case .cellDelta: return "压差 " + (reading.cellDelta.map { String(format: "%.0fmV", $0 * 1000) } ?? "--mV")
            }
        }
    }

    public enum Size: Int, CaseIterable {
        case small, medium, large
        public var title: String { ["小", "中", "大"][rawValue] }
        /// Both compositors use this fraction of their video width.
        public var widthFraction: Double { [0.36, 0.46, 0.58][rawValue] }
    }

    public static let compactFields: [Field] = [.charge, .voltage, .cellDelta]
    public private(set) var fields: [Field]
    public var size: Size

    /// Missing/invalid saved preferences preserve the original six-field card.
    public init(savedFields: [String]? = nil, sizeRawValue: Int? = nil) {
        let known = Set(savedFields?.compactMap(Field.init(rawValue:)) ?? Field.allCases)
        let normalized = Field.allCases.filter { known.contains($0) }
        fields = normalized.isEmpty ? Field.allCases : normalized
        size = sizeRawValue.flatMap(Size.init(rawValue:)) ?? .medium
    }

    /// Keep at least one metric visible, and a stable order across app launches.
    @discardableResult
    public mutating func set(_ field: Field, visible: Bool) -> Bool {
        if !visible, fields == [field] { return false }
        var selected = Set(fields)
        if visible { selected.insert(field) } else { selected.remove(field) }
        fields = Field.allCases.filter { selected.contains($0) }
        return true
    }

    public func lines(for reading: ANTBMSReading) -> [String] {
        let tokens = fields.map { $0.text(reading) }
        let split = tokens.count <= 3 ? tokens.count : (tokens.count + 1) / 2
        var lines = ["ANT  " + tokens.prefix(split).joined(separator: "  ")]
        if reading.hasAlarm { lines[0] += " · 告警" }
        if split < tokens.count { lines.append(tokens.dropFirst(split).joined(separator: "  ")) }
        return lines
    }
}
