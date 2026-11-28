import UIKit

/// Noninteractive surface follows video bounds, including rotation and fullscreen changes.
private final class BMSOverlaySurface: UIView {
    let imageView = UIImageView()
    var configuration = ANTBMSCardConfiguration() { didSet { setNeedsLayout() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "电池实时信息"
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image?.cgImage else { return }
        imageView.frame = configuration.overlayFrame(in: bounds, imageSize: CGSize(width: image.width, height: image.height))
    }
}

/// The same bitmap and normalized placement feed local video, Ninebot and ZEEHO.
final class BMSOverlayPresenter {
    private let surface = BMSOverlaySurface()
    private var cachedText: String?
    private var cachedImage: CGImage?
    private var cachedConfiguration: ANTBMSCardConfiguration?
    var onImage: ((CGImage?, ANTBMSCardConfiguration) -> Void)?

    func attach(to view: UIView) {
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.isHidden = true
        view.addSubview(surface)
        NSLayoutConstraint.activate([surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor), surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        cachedConfiguration = nil
    }
    func update(enabled: Bool, reading: ANTBMSReading?, status: String, configuration: ANTBMSCardConfiguration) {
        if !enabled || reading == nil && configuration.lossDisplay == .hidden {
            let wasVisible = !surface.isHidden
            surface.isHidden = true; cachedText = nil; cachedImage = nil; cachedConfiguration = nil
            surface.imageView.image = nil
            if wasVisible { onImage?(nil, configuration) }
            return
        }
        let text = reading.map { configuration.lines(for: $0).joined(separator: "\n") + "|\($0.stateCode)|\($0.available.contains("state"))" }
            ?? "电池 · 无实时数据"
        let changed = text != cachedText || cachedConfiguration != configuration || surface.isHidden
        if text != cachedText || cachedConfiguration?.style != configuration.style || cachedConfiguration?.background != configuration.background {
            cachedImage = BMSCardRenderer.render(reading, configuration: configuration)
            surface.imageView.image = cachedImage.map { UIImage(cgImage: $0) }
            surface.imageView.accessibilityValue = reading.map { configuration.lines(for: $0).joined(separator: "，") } ?? "无实时数据"
        }
        cachedText = text; cachedConfiguration = configuration
        surface.configuration = configuration; surface.isHidden = false
        surface.setNeedsLayout()
        if changed { onImage?(cachedImage, configuration) }
    }
    static func preview(_ reading: ANTBMSReading, configuration: ANTBMSCardConfiguration) -> CGImage? {
        BMSCardRenderer.render(reading, configuration: configuration)
    }
}
