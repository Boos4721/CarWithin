import UIKit

/// A small set of state rows. Labels wrap independently at large text sizes.
final class ConnectionOverviewView: UIView {
    private let vehicle = UIButton(type: .system)
    private let wifi = UIButton(type: .system)
    private let carPlay = UILabel()
    private let output = UIButton(type: .system)
    private let battery = UIButton(type: .system)
    var onVehicle: (() -> Void)?
    var onWiFi: (() -> Void)?
    var onOutput: (() -> Void)?
    var onBattery: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        let actions: [(UIButton, String, () -> Void)] = [(vehicle, "scooter", { [weak self] in self?.onVehicle?() }),
            (wifi, "wifi", { [weak self] in self?.onWiFi?() }),
            (output, "rectangle.connected.to.line.below", { [weak self] in self?.onOutput?() }),
            (battery, "battery.100percent", { [weak self] in self?.onBattery?() })]
        for (button, symbol, action) in actions {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol); configuration.imagePadding = 10
            configuration.baseForegroundColor = .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
            configuration.titleLineBreakMode = .byWordWrapping
            button.configuration = configuration; button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 0
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        carPlay.font = .preferredFont(forTextStyle: .subheadline); carPlay.adjustsFontForContentSizeCategory = true
        carPlay.numberOfLines = 0
        [vehicle, wifi, carPlay, output, battery].forEach { stack.addArrangedSubview($0) }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(vehicle: String, canSwitch: Bool, connection: ConnectionOverview, output: String?, battery: String) {
        self.vehicle.configuration?.title = vehicle + " · 车辆配置"
        self.vehicle.isEnabled = canSwitch
        wifi.configuration?.title = "Wi-Fi：" + connection.wifi
        carPlay.text = "CarPlay：" + connection.carPlay
        self.output.configuration?.title = output.map { "仪表／输出：" + $0 }
        self.output.isHidden = output == nil
        self.battery.configuration?.title = "电池：" + battery
    }
}

final class BMSRecordSummaryView: UIView {
    private let heading = StatusLabel()
    private let summary = StatusLabel()
    private let detail = StatusLabel()
    private let button = UIButton(type: .system)
    var onDetails: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        for (label, style) in [(heading, UIFont.TextStyle.headline), (summary, .body), (detail, .footnote)] {
            label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
        }
        detail.textColor = .secondaryLabel
        button.configuration = .tinted(); button.configuration?.title = "查看记录详情"
        button.configuration?.titleLineBreakMode = .byWordWrapping
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.onDetails?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [heading, summary, detail, button]); stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)])
        backgroundColor = .secondarySystemGroupedBackground; layer.cornerRadius = 20; layer.cornerCurve = .continuous
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(title: String, statistics: ANTBMSSessionStatistics, context: String) {
        let value = BMSRecordSummary(statistics: statistics)
        isHidden = !value.hasSamples
        heading.text = title
        summary.text = value.duration + " · " + value.charge
        detail.text = ([context, value.coverage, value.details].filter { !$0.isEmpty }).joined(separator: "\n")
    }
}
