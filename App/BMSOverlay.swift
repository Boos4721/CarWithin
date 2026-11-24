import CoreImage
import UIKit

/// Renders a small, noninteractive telemetry panel once per changed text. The
/// same bitmap is shown locally and composited into Ninebot's encoded video.
final class BMSOverlayPresenter {
    private let imageView = UIImageView()
    private var cachedText: String?
    private var cachedImage: CGImage?
    private var constraints: [NSLayoutConstraint] = []
    private var positionAtTop: Bool?
    private var widthFraction = 0.46
    private var renderedLineCount = 2
    var onImage: ((CGImage?, Bool, Double) -> Void)?

    func attach(to surface: UIView) {
        imageView.isUserInteractionEnabled = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "电池实时信息"
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(imageView)
        layout(on: surface, atTop: true)
    }

    func update(enabled: Bool, reading: ANTBMSReading?, status: String, atTop: Bool,
                configuration: ANTBMSCardConfiguration) {
        guard enabled else {
            let wasVisible = !imageView.isHidden
            imageView.isHidden = true
            cachedText = nil; cachedImage = nil
            if wasVisible { onImage?(nil, atTop, configuration.size.widthFraction) }
            return
        }
        let text: String
        if let reading {
            text = configuration.lines(for: reading).joined(separator: "\n")
        } else {
            text = "ANT BMS · 无实时数据\n" + (status.contains("过期") || status.contains("断开") || status.contains("重连")
                ? "连接失联，等待恢复" : "等待电池数据")
        }
        let nextWidth = configuration.size.widthFraction
        let changed = text != cachedText || positionAtTop != atTop || widthFraction != nextWidth || imageView.isHidden
        let needsLayout = renderedLineCount != text.components(separatedBy: "\n").count
            || positionAtTop != atTop || widthFraction != nextWidth
        widthFraction = nextWidth
        if text != cachedText {
            cachedText = text
            cachedImage = render(text, alarm: reading?.hasAlarm == true)
            imageView.image = cachedImage.map { UIImage(cgImage: $0) }
            imageView.accessibilityValue = text.replacingOccurrences(of: "\n", with: "，")
        }
        imageView.isHidden = false
        if let surface = imageView.superview, needsLayout { layout(on: surface, atTop: atTop) }
        if changed { onImage?(cachedImage, atTop, widthFraction) }
    }

    private func layout(on surface: UIView, atTop: Bool) {
        positionAtTop = atTop
        NSLayoutConstraint.deactivate(constraints)
        constraints = [
            imageView.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
            imageView.widthAnchor.constraint(equalTo: surface.widthAnchor, multiplier: CGFloat(widthFraction)),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor,
                multiplier: CGFloat(renderedLineCount == 1 ? 72 : 122) / 640),
            atTop ? imageView.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6)
                  : imageView.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6)
        ]
        NSLayoutConstraint.activate(constraints)
    }

    private func render(_ text: String, alarm: Bool) -> CGImage? {
        renderedLineCount = min(2, text.components(separatedBy: "\n").count)
        let size = CGSize(width: 640, height: renderedLineCount == 1 ? 72 : 122)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.withAlphaComponent(0.86).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 16).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let color: UIColor = alarm ? .systemOrange : .white
            for (index, line) in text.components(separatedBy: "\n").prefix(2).enumerated() {
                let baseFont = UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .semibold)
                let width = (line as NSString).size(withAttributes: [.font: baseFont]).width
                let font = UIFont.monospacedDigitSystemFont(ofSize: min(36, max(18, 36 * 604 / max(1, width))), weight: .semibold)
                (line as NSString).draw(in: CGRect(x: 18, y: CGFloat(12 + index * 50), width: 604, height: 48), withAttributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: paragraph
                ])
            }
        }.cgImage
    }
}
