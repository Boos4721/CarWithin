import CoreGraphics
import Foundation

/// Shared card content and scale for the phone and instrument video.
public struct ANTBMSCardConfiguration: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
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

        public func text(_ reading: ANTBMSReading) -> String {
            if [.charge, .voltage, .current, .power].contains(self), !reading.available.contains(rawValue) {
                return self == .charge ? "--%" : self == .voltage ? "--V" : self == .current ? "--A" : "--W"
            }
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

    public enum Size: Int, CaseIterable, Sendable {
        case small, medium, large
        public var title: String { ["小", "中", "大"][rawValue] }
        /// Both compositors use this fraction of their video width.
        public var widthFraction: Double { [0.36, 0.46, 0.58][rawValue] }
    }

    /// Keep the two original right-side values so existing preferences migrate.
    public enum Position: Int, CaseIterable, Sendable {
        case topRight, bottomRight, topLeft, bottomLeft
        public var title: String { ["右上角", "右下角", "左上角", "左下角"][rawValue] }
        public var isAtTop: Bool { self == .topRight || self == .topLeft }
        public var isAtRight: Bool { self == .topRight || self == .bottomRight }
    }

    public enum Background: Int, CaseIterable, Sendable {
        case light, standard, opaque
        public var title: String { ["轻透", "标准", "不透明"][rawValue] }
        public var opacity: Double { [0.45, 0.86, 1][rawValue] }
    }

    public enum Mode: Int, CaseIterable, Sendable {
        case automatic, custom
        public var title: String { self == .automatic ? "自动推荐" : "自定义" }
    }
    public enum Style: Int, CaseIterable, Sendable {
        case classic, prominent
        public var title: String { self == .classic ? "经典两行" : "大字卡片" }
    }
    public enum LossDisplay: Int, CaseIterable, Sendable {
        case compact, hidden
        public var title: String { self == .compact ? "紧凑提示" : "隐藏卡片" }
    }
    public enum Scene: String, CaseIterable, Sendable {
        case riding, monitoring, charging
        public var title: String {
            switch self { case .riding: "骑行简洁"; case .monitoring: "电池监测"; case .charging: "充电" }
        }
        public var fields: [Field] {
            switch self {
            case .riding: [.charge, .voltage, .power]
            case .monitoring: [.charge, .voltage, .temperature, .cellDelta]
            case .charging: [.charge, .current, .power, .temperature]
            }
        }
    }
    public struct Anchor: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x.isFinite ? min(1, max(0, x)) : 0.5
            self.y = y.isFinite ? min(1, max(0, y)) : 0.5
        }
    }
    public var style: Style
    public var lossDisplay: LossDisplay
    public var customAnchor: Anchor?
    public var anchor: Anchor {
        customAnchor ?? Anchor(x: position.isAtRight ? 1 : 0, y: position.isAtTop ? 0 : 1)
    }
    /// Top-left coordinates shared by settings and video; position is a fraction of available travel.
    public func overlayFrame(in bounds: CGRect, imageSize: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let margin = min(max(6, bounds.width * 0.007), min(bounds.width, bounds.height) / 4)
        let scale = min(bounds.width * CGFloat(size.widthFraction) / imageSize.width,
                        (bounds.height - 2 * margin) / imageSize.height,
                        (bounds.width - 2 * margin) / imageSize.width)
        let width = imageSize.width * scale, height = imageSize.height * scale
        return CGRect(x: bounds.minX + margin + (bounds.width - 2 * margin - width) * CGFloat(anchor.x),
                      y: bounds.minY + margin + (bounds.height - 2 * margin - height) * CGFloat(anchor.y),
                      width: width, height: height)
    }
    public mutating func snap(to position: Position) { self.position = position; customAnchor = nil }
    public mutating func apply(_ scene: Scene) {
        fields = scene.fields; mode = .custom; style = .prominent
    }
    public var mode: Mode
    public static let compactFields: [Field] = [.charge, .voltage, .cellDelta]
    public private(set) var fields: [Field]
    public var size: Size
    public var position: Position
    public var background: Background

    /// Missing/invalid saved preferences preserve the original six-field card.
    public init(savedFields: [String]? = nil, sizeRawValue: Int? = nil,
                positionRawValue: Int? = nil, backgroundRawValue: Int? = nil, modeRawValue: Int? = nil,
                styleRawValue: Int? = nil, lossDisplayRawValue: Int? = nil,
                anchorX: Double? = nil, anchorY: Double? = nil) {
        style = styleRawValue.flatMap(Style.init(rawValue:)) ?? .classic
        lossDisplay = lossDisplayRawValue.flatMap(LossDisplay.init(rawValue:)) ?? .compact
        if let anchorX, let anchorY, anchorX.isFinite, anchorY.isFinite {
            customAnchor = Anchor(x: anchorX, y: anchorY)
        } else { customAnchor = nil }
        mode = modeRawValue.flatMap(Mode.init(rawValue:)) ?? .custom
        var seen = Set<Field>()
        let normalized = (savedFields?.compactMap(Field.init(rawValue:)) ?? Field.allCases)
            .filter { seen.insert($0).inserted }
        fields = normalized.isEmpty ? Field.allCases : normalized
        size = sizeRawValue.flatMap(Size.init(rawValue:)) ?? .medium
        position = positionRawValue.flatMap(Position.init(rawValue:)) ?? .topRight
        background = backgroundRawValue.flatMap(Background.init(rawValue:)) ?? .standard
    }

    /// Resolve a temporary render layout without changing the saved custom fields.
    public func resolving(recommendedFields: [Field]) -> Self {
        guard mode == .automatic, !recommendedFields.isEmpty else { return self }
        var result = self
        result.fields = recommendedFields
        return result
    }

    /// Keep at least one metric visible, preserving the user's preferred order.
    @discardableResult
    public mutating func set(_ field: Field, visible: Bool) -> Bool {
        if !visible, fields == [field] { return false }
        mode = .custom
        if visible {
            if !fields.contains(field) { fields.append(field) }
        } else { fields.removeAll { $0 == field } }
        return true
    }

    public mutating func move(_ field: Field, to destination: Int) {
        guard let index = fields.firstIndex(of: field), fields.indices.contains(destination) else { return }
        mode = .custom
        fields.remove(at: index)
        fields.insert(field, at: destination)
    }

    public func lines(for reading: ANTBMSReading) -> [String] {
        let tokens = fields.map { $0.text(reading) }
        let split = tokens.count <= 3 ? tokens.count : (tokens.count + 1) / 2
        var lines = [reading.family.shortName + "  " + tokens.prefix(split).joined(separator: "  ")]
        if reading.hasAlarm { lines[0] += " · 告警" }
        if split < tokens.count { lines.append(tokens.dropFirst(split).joined(separator: "  ")) }
        return lines
    }
}
