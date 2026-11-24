import UIKit

final class BMSVoltageTrendView: UIView {
    var points: [ANTBMSSessionStatistics.Point] = [] {
        didSet {
            accessibilityValue = points.last.map { String(format: "最近电压 %.2f 伏，%d 个趋势采样点", $0.voltage, points.count) }
                ?? "等待至少两个采样点"
            setNeedsDisplay()
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; isAccessibilityElement = true; accessibilityLabel = "本次电压趋势"
        heightAnchor.constraint(equalToConstant: 150).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard points.count >= 2, let first = points.first, let last = points.last else {
            ("收到数据后显示电压趋势" as NSString).draw(at: CGPoint(x: 12, y: 60), withAttributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel])
            return
        }
        let values = points.map(\.voltage)
        let low = (values.min() ?? 0) - 0.05, high = (values.max() ?? 0) + 0.05
        let area = bounds.inset(by: UIEdgeInsets(top: 26, left: 8, bottom: 22, right: 8))
        let duration = max(last.elapsed - first.elapsed, 1)
        let path = UIBezierPath()
        var previous: ANTBMSSessionStatistics.Point?
        for point in points {
            let position = CGPoint(x: area.minX + CGFloat((point.elapsed - first.elapsed) / duration) * area.width,
                y: area.maxY - CGFloat((point.voltage - low) / (high - low)) * area.height)
            if previous == nil || point.elapsed - previous!.elapsed > 10 { path.move(to: position) }
            else { path.addLine(to: position) }
            previous = point
        }
        UIColor.systemBlue.setStroke(); path.lineWidth = 2; path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel]
        (String(format: "%.2f–%.2f V", low + 0.05, high - 0.05) as NSString)
            .draw(at: CGPoint(x: 8, y: 4), withAttributes: attributes)
        (String(format: "最近 %.0f 秒", duration) as NSString)
            .draw(at: CGPoint(x: 8, y: bounds.height - 18), withAttributes: attributes)
    }
}
