import UIKit

/// A schematic background, using the same bitmap and scale as the real video.
/// Example readings stay in this settings view and never enter live telemetry.
final class BMSCardPreviewView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((ANTBMSCardConfiguration.Anchor) -> Void)?
    private var dragging = false
    private var dragOrigin = CGPoint.zero
    private var dragStart: ANTBMSCardConfiguration.Anchor?
    var configuration = ANTBMSCardConfiguration() { didSet { setNeedsDisplay() } }
    var image: CGImage? { didSet { setNeedsDisplay() } }
    var videoAspectRatio: CGFloat = 848 / 480 {
        didSet {
            guard videoAspectRatio != oldValue else { return }
            aspectConstraint?.isActive = false
            aspectConstraint = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 1 / max(0.1, videoAspectRatio))
            aspectConstraint?.isActive = true
        }
    }
    private var aspectConstraint: NSLayoutConstraint?
    private var renderedText: [String]?
    private var renderedState: Int?
    private var renderedHasState = false
    private var renderedConfiguration: ANTBMSCardConfiguration?

    func update(reading: ANTBMSReading?, configuration: ANTBMSCardConfiguration, aspectRatio: CGFloat, family: BMSFamily? = nil) {
        if !dragging, self.configuration != configuration { self.configuration = configuration }
        videoAspectRatio = aspectRatio
        var previewReading = reading ?? Self.example
        if reading == nil, let family { previewReading.family = family }
        let text = configuration.lines(for: previewReading)
        if renderedText != text || renderedState != previewReading.stateCode || renderedHasState != previewReading.available.contains("state") || renderedConfiguration?.style != configuration.style || renderedConfiguration?.background != configuration.background {
            renderedText = text; renderedConfiguration = configuration
            renderedState = previewReading.stateCode; renderedHasState = previewReading.available.contains("state")
            image = BMSOverlayPresenter.preview(previewReading, configuration: configuration)
        }
        accessibilityValue = (reading == nil ? "示例数据，非实时读数。" : "实时数据。")
            + (self.configuration.customAnchor == nil ? configuration.position.title : "自定义位置") + "，" + text.joined(separator: "，")
    }

    static let example = ANTBMSReading(voltage: 82.78, current: -12.3, power: -1018, stateOfCharge: 78,
        stateOfHealth: nil, stateCode: 4, capacityAh: 170, remainingAh: 131.92, cells: [4.1, 4.106],
        temperatures: [14], mosTemperature: 15, protectionBits: 0, warningBits: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; isAccessibilityElement = true; accessibilityLabel = "BMS 卡片布局预览"
        layer.cornerRadius = 12; clipsToBounds = true
        aspectConstraint = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 480 / 848)
        aspectConstraint?.isActive = true
        accessibilityHint = "拖动卡片调整位置，也可以使用下方位置菜单和微调按钮。"
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self; addGestureRecognizer(pan)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "向左移动") { [weak self] _ in self?.nudge(dx: -0.05, dy: 0) ?? false },
            UIAccessibilityCustomAction(name: "向右移动") { [weak self] _ in self?.nudge(dx: 0.05, dy: 0) ?? false },
            UIAccessibilityCustomAction(name: "向上移动") { [weak self] _ in self?.nudge(dx: 0, dy: -0.05) ?? false },
            UIAccessibilityCustomAction(name: "向下移动") { [weak self] _ in self?.nudge(dx: 0, dy: 0.05) ?? false }
        ]
    }
    private var cardFrame: CGRect {
        guard let image else { return .zero }
        return configuration.overlayFrame(in: bounds, imageSize: CGSize(width: image.width, height: image.height))
    }
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        let location = recognizer.location(in: self)
        return location.x > 16 && cardFrame.insetBy(dx: -12, dy: -12).contains(location)
    }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: dragging = true; dragOrigin = cardFrame.origin; dragStart = configuration.customAnchor
        case .changed, .ended:
            let translation = recognizer.translation(in: self), frame = cardFrame
            let margin = min(max(6, bounds.width * 0.007), min(bounds.width, bounds.height) / 4)
            let x = Double((dragOrigin.x + translation.x - bounds.minX - margin) / max(1, bounds.width - 2 * margin - frame.width))
            let y = Double((dragOrigin.y + translation.y - bounds.minY - margin) / max(1, bounds.height - 2 * margin - frame.height))
            configuration.customAnchor = .init(x: x, y: y)
            if recognizer.state == .ended, let anchor = configuration.customAnchor { dragging = false; onMove?(anchor) }
        case .cancelled, .failed: dragging = false; configuration.customAnchor = dragStart
        default: break
        }
    }
    @discardableResult
    func nudge(dx: Double, dy: Double) -> Bool {
        let old = configuration.anchor
        let anchor = ANTBMSCardConfiguration.Anchor(x: old.x + dx, y: old.y + dy)
        guard anchor != old else { return false }
        configuration.customAnchor = anchor; onMove?(anchor); return true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        UIColor.secondarySystemBackground.setFill(); UIRectFill(bounds)
        let roads = UIBezierPath()
        for x in stride(from: CGFloat(24), to: bounds.width, by: 54) {
            roads.move(to: CGPoint(x: x, y: 0)); roads.addLine(to: CGPoint(x: x + 24, y: bounds.height))
        }
        for y in stride(from: CGFloat(22), to: bounds.height, by: 42) {
            roads.move(to: CGPoint(x: 0, y: y)); roads.addLine(to: CGPoint(x: bounds.width, y: y + 12))
        }
        UIColor.separator.withAlphaComponent(0.45).setStroke(); roads.lineWidth = 7; roads.stroke()
        let route = UIBezierPath()
        route.move(to: CGPoint(x: bounds.width * 0.3, y: bounds.height))
        route.addLine(to: CGPoint(x: bounds.width * 0.4, y: bounds.height * 0.52))
        route.addLine(to: CGPoint(x: bounds.width * 0.63, y: bounds.height * 0.52))
        route.addLine(to: CGPoint(x: bounds.width * 0.68, y: 0))
        UIColor.systemBlue.withAlphaComponent(0.7).setStroke(); route.lineWidth = 5; route.lineJoinStyle = .round; route.stroke()
        guard let image else { return }
        UIImage(cgImage: image).draw(in: cardFrame)
        UIColor.systemBlue.withAlphaComponent(0.8).setStroke()
        let outline = UIBezierPath(roundedRect: cardFrame.insetBy(dx: -2, dy: -2), cornerRadius: 5)
        outline.setLineDash([4, 3], count: 2, phase: 0); outline.lineWidth = 1; outline.stroke()
    }
}
