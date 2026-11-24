import UIKit

final class BMSVoltageTrendView: UIView {
    var points: [ANTBMSSessionStatistics.Point] = [] {
        didSet {
            if let low = points.map(\.lowerVoltage).min(), let high = points.map(\.upperVoltage).max() {
                let source = points.allSatisfy { $0.minimumVoltage != nil } ? "包含区间极值" : "旧版抽样，可能遗漏瞬时压降"
                accessibilityValue = String(format: "曲线范围 %.2f 至 %.2f 伏，%@", low, high, source)
            } else { accessibilityValue = "等待电压数据" }
            setNeedsDisplay()
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; isAccessibilityElement = true; accessibilityLabel = "本次电压趋势"
        heightAnchor.constraint(equalToConstant: 210).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel]
        guard let first = points.first, let last = points.last,
              let minimum = points.map(\.lowerVoltage).min(), let maximum = points.map(\.upperVoltage).max() else {
            ("收到数据后显示电压趋势" as NSString).draw(at: CGPoint(x: 8, y: 80), withAttributes: attributes)
            return
        }
        let hasExtrema = points.allSatisfy { $0.minimumVoltage != nil && $0.maximumVoltage != nil }
        let title = String(format: hasExtrema ? "趋势范围 %.2f–%.2f V" : "旧版抽样 %.2f–%.2f V", minimum, maximum)
        (title as NSString).draw(at: CGPoint(x: 4, y: 4), withAttributes: attributes)
        let padding = max(0.05, (maximum - minimum) * 0.08)
        let low = minimum - padding, high = maximum + padding
        let area = bounds.inset(by: UIEdgeInsets(top: 30, left: 48, bottom: 60, right: 8))
        guard area.width > 0, area.height > 0 else { return }
        let duration = max(last.latestElapsed - first.elapsed, 1)
        func x(_ elapsed: Double) -> CGFloat {
            area.minX + CGFloat((elapsed - first.elapsed) / duration) * area.width
        }
        func y(_ voltage: Double) -> CGFloat {
            area.maxY - CGFloat((voltage - low) / (high - low)) * area.height
        }
        for voltage in [high, (high + low) / 2, low] {
            let line = UIBezierPath()
            line.move(to: CGPoint(x: area.minX, y: y(voltage)))
            line.addLine(to: CGPoint(x: area.maxX, y: y(voltage)))
            UIColor.separator.withAlphaComponent(0.35).setStroke(); line.lineWidth = 0.5; line.stroke()
            (String(format: "%.2f", voltage) as NSString)
                .draw(at: CGPoint(x: 0, y: y(voltage) - 7), withAttributes: attributes)
        }
        let path = UIBezierPath()
        var previous: ANTBMSSessionStatistics.Point?
        for point in points {
            let position = CGPoint(x: x(point.latestElapsed), y: y(point.voltage))
            if previous == nil || point.startsSegment == true
                || point.elapsed - previous!.latestElapsed > 10 { path.move(to: position) }
            else { path.addLine(to: position) }
            if point.minimumVoltage != nil {
                let range = UIBezierPath()
                range.move(to: CGPoint(x: position.x, y: y(point.lowerVoltage)))
                range.addLine(to: CGPoint(x: position.x, y: y(point.upperVoltage)))
                UIColor.systemBlue.withAlphaComponent(0.35).setStroke()
                range.lineWidth = min(6, max(2, area.width / CGFloat(points.count) * 0.35))
                range.lineCapStyle = .round
                range.stroke()
            }
            previous = point
        }
        UIColor.systemBlue.setStroke(); path.lineWidth = 2; path.stroke()
        UIColor.systemBlue.setFill()
        UIBezierPath(ovalIn: CGRect(x: x(last.latestElapsed) - 2.5, y: y(last.voltage) - 2.5, width: 5, height: 5)).fill()
        func elapsedLabel(_ seconds: Double) -> NSString {
            String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) as NSString
        }
        let start = elapsedLabel(first.elapsed), end = elapsedLabel(last.latestElapsed)
        start.draw(at: CGPoint(x: area.minX, y: area.maxY + 5), withAttributes: attributes)
        end.draw(at: CGPoint(x: max(area.minX, area.maxX - end.size(withAttributes: attributes).width), y: area.maxY + 5), withAttributes: attributes)
        let note = hasExtrema ? "蓝线：区间最新电压 · 竖条：最低至最高" : "旧记录仅保存抽样，无法补回瞬时压降"
        (note as NSString).draw(in: CGRect(x: 4, y: bounds.height - 22, width: bounds.width - 8, height: 20), withAttributes: attributes)
    }
}
