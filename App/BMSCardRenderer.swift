import CoreGraphics
import CoreText
import Foundation

/// Bitmap renderer shared by the phone and every instrument. No simulated values enter this path.
enum BMSCardRenderer {
    static func render(_ reading: ANTBMSReading?, configuration: ANTBMSCardConfiguration) -> CGImage? {
        if reading == nil, configuration.lossDisplay == .hidden { return nil }
        let fields = configuration.fields
        let secondaryCount = max(0, fields.count - 1)
        let rows = secondaryCount <= 2 ? secondaryCount : (secondaryCount + 1) / 2
        let height: Int
        if reading == nil { height = 64 }
        else if configuration.style == .classic { height = fields.count <= 3 ? 72 : 122 }
        else { height = max(190, 64 + rows * 66) }
        guard let context = CGContext(data: nil, width: 640, height: height, bitsPerComponent: 8, bytesPerRow: 2560,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: configuration.background.opacity))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 640, height: height), cornerWidth: 16, cornerHeight: 16, transform: nil))
        context.fillPath()
        let white = CGColor(gray: 1, alpha: 1), muted = CGColor(gray: 0.83, alpha: 1)
        let orange = CGColor(red: 1, green: 0.7, blue: 0.25, alpha: 1)
        func text(_ string: String, _ rect: CGRect, size: CGFloat, color: CGColor = CGColor(gray: 1, alpha: 1)) {
            var font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
            func line(_ font: CTFont) -> CTLine {
                let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
                return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            }
            var value = line(font)
            let width = CGFloat(CTLineGetTypographicBounds(value, nil, nil, nil))
            if width > rect.width {
                font = CTFontCreateCopyWithAttributes(font, max(12, size * rect.width / max(1, width)), nil, nil)
                value = line(font)
            }
            context.saveGState()
            context.clip(to: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: rect.minX, y: CGFloat(height) - rect.minY - CTFontGetAscent(font))
            CTLineDraw(value, context)
            context.restoreGState()
        }
        guard let reading else {
            text("电池 · 无实时数据", CGRect(x: 20, y: 12, width: 600, height: 44), size: 32, color: muted)
            return context.makeImage()
        }
        if configuration.style == .classic {
            for (index, line) in configuration.lines(for: reading).enumerated() {
                text(line, CGRect(x: 18, y: 12 + index * 50, width: 604, height: 48), size: 36, color: reading.hasAlarm ? orange : white)
            }
        } else {
            let state: String
            if reading.hasAlarm { state = "设备告警" }
            else if reading.available.contains("state") {
                state = [1: "静止", 2: "充电", 3: "待机", 4: "放电"][reading.stateCode] ?? "实时"
            } else { state = "实时" }
            text(reading.family.shortName, CGRect(x: 20, y: 12, width: 290, height: 32), size: 26, color: muted)
            text(state, CGRect(x: 470, y: 12, width: 150, height: 32), size: 26, color: reading.hasAlarm ? orange : muted)
            if let first = fields.first {
                let metric = first.displayMetric(reading)
                text(metric.value, CGRect(x: 20, y: 52, width: 218, height: 94), size: 82)
                text(metric.unit + " · " + first.title, CGRect(x: 22, y: 144, width: 220, height: 28), size: 22, color: muted)
            }
            let columns = secondaryCount <= 2 ? 1 : 2
            for (index, field) in fields.dropFirst().enumerated() {
                let metric = field.displayMetric(reading)
                let width: CGFloat = columns == 1 ? 346 : 164
                let x: CGFloat = 270 + CGFloat(index % columns) * 182
                let y: CGFloat = 52 + CGFloat(index / columns) * 66
                text(field.title, CGRect(x: x, y: y, width: width, height: 24), size: 20, color: muted)
                text(metric.value + metric.unit, CGRect(x: x, y: y + 25, width: width, height: 38), size: 32)
            }
        }
        return context.makeImage()
    }
}

extension ANTBMSCardConfiguration.Field {
    func displayMetric(_ reading: ANTBMSReading) -> (value: String, unit: String) {
        let available = reading.available
        switch self {
        case .charge: return (available.contains("charge") ? String(reading.stateOfCharge) : "--", "%")
        case .voltage: return (available.contains("voltage") ? String(format: "%.2f", reading.voltage) : "--", "V")
        case .current: return (available.contains("current") ? String(format: "%+.1f", reading.current) : "--", "A")
        case .power:
            guard available.contains("power") else { return ("--", "W") }
            return abs(Double(reading.power)) >= 1000 ? (String(format: "%.2f", Double(reading.power) / 1000), "kW") : (String(reading.power), "W")
        case .temperature: return (reading.maximumTemperature.map { String(format: "%.0f", $0) } ?? "--", "°C")
        case .cellDelta: return (reading.cellDelta.map { String(format: "%.0f", $0 * 1000) } ?? "--", "mV")
        }
    }
}
