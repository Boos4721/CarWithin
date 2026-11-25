import UIKit

/// Live connection status with one relevant recovery action; never embeds raw log text as state.
final class BMSStatusCardView: UIView {
    private let name = UILabel()
    private let brand = UILabel()
    private let state = UILabel()
    private let detail = UILabel()
    private let symbol = UIImageView()
    private let button = UIButton(type: .system)
    var onAction: (() -> Void)?
    private var layoutSignature = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        for (label, style) in [(name, UIFont.TextStyle.headline), (brand, .subheadline), (state, .subheadline), (detail, .footnote)] {
            label.font = .preferredFont(forTextStyle: style)
            label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
        }
        brand.textColor = .secondaryLabel; detail.textColor = .secondaryLabel
        symbol.contentMode = .scaleAspectFit
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.widthAnchor.constraint(equalToConstant: 22).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 22).isActive = true
        symbol.isAccessibilityElement = false
        let statusRow = UIStackView(arrangedSubviews: [symbol, state]); statusRow.spacing = 8; statusRow.alignment = .center
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .medium
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming; result.font = .preferredFont(forTextStyle: .body); return result
        }
        button.configuration = configuration; button.titleLabel?.numberOfLines = 0
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [name, brand, statusRow, detail, button])
        stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(name: String, family: BMSFamily?, presentation: BMSConnectionPresentation) {
        self.name.text = name
        brand.text = family?.title; brand.isHidden = family == nil
        state.text = presentation.title; detail.text = presentation.detail
        let color: UIColor
        let icon: String
        switch presentation.tone {
        case .good: color = .systemGreen; icon = "checkmark.circle.fill"
        case .working: color = .systemBlue; icon = "arrow.triangle.2.circlepath"
        case .attention: color = .systemOrange; icon = "exclamationmark.circle.fill"
        case .neutral: color = .secondaryLabel; icon = "battery.100percent"
        }
        state.textColor = .label; symbol.tintColor = color; symbol.image = UIImage(systemName: icon)
        button.configuration?.title = presentation.actionTitle
        button.isHidden = presentation.actionTitle == nil
        // Re-measure only when wrapping or button visibility may change, not on every BLE callback.
        let signature = name + (family?.rawValue ?? "") + presentation.title + presentation.detail + String(button.isHidden)
        if layoutSignature != signature {
            layoutSignature = signature
            NotificationCenter.default.post(name: StatusLabel.didChange, object: self)
        }
    }
}
