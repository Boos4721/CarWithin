import UIKit

/// Per-slot cells with text markers as well as colors. No data is fabricated for summary-only boards.
final class BMSCellGridView: UIView {
    private let summary = UILabel()
    private let message = UILabel()
    private let grid = UIStackView()
    private let stack = UIStackView()
    private var cellLabels: [(UILabel, UILabel, UILabel, UIStackView)] = []
    private var reading: ANTBMSReading?
    private var columns = 0
    private var slotCount = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [summary, message] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
        }
        message.textColor = .secondaryLabel
        grid.axis = .vertical; grid.spacing = 8
        stack.axis = .vertical; stack.spacing = 12
        for view in [summary, message, grid] { stack.addArrangedSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        NotificationCenter.default.addObserver(self, selector: #selector(fontChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func fontChanged() { columns = 0; setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let nextColumns = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 1 : (bounds.width >= 480 ? 4 : 3)
        if columns != nextColumns { columns = nextColumns; rebuild() }
    }
    func update(_ reading: ANTBMSReading?) {
        self.reading = reading
        let count = min(64, reading?.cells.count ?? 0)
        if count != slotCount { slotCount = count; rebuild() }
        refreshValues()
    }
    private func rebuild() {
        for row in grid.arrangedSubviews { grid.removeArrangedSubview(row); row.removeFromSuperview() }
        cellLabels.removeAll()
        let count = max(0, slotCount), width = max(1, columns)
        for offset in stride(from: 0, to: count, by: width) {
            let row = UIStackView(); row.spacing = 8; row.distribution = .fillEqually
            for index in offset..<min(offset + width, count) {
                let title = UILabel(), value = UILabel(), marker = UILabel()
                title.text = "\(index + 1) 串"
                for (label, style) in [(title, UIFont.TextStyle.caption1), (value, .headline), (marker, .caption2)] {
                    label.font = .preferredFont(forTextStyle: style)
                    label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
                }
                title.textColor = .secondaryLabel; marker.textColor = .secondaryLabel
                let tile = UIStackView(arrangedSubviews: [title, value, marker]); tile.axis = .vertical; tile.spacing = 4
                tile.isLayoutMarginsRelativeArrangement = true
                tile.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
                tile.layer.cornerRadius = 10; tile.isAccessibilityElement = true
                row.addArrangedSubview(tile); cellLabels.append((title, value, marker, tile))
            }
            for _ in min(offset + width, count)..<(offset + width) { row.addArrangedSubview(UIView()) }
            grid.addArrangedSubview(row)
        }
        refreshValues()
        NotificationCenter.default.post(name: StatusLabel.didChange, object: self)
    }
    private func refreshValues() {
        guard let reading else {
            summary.text = "等待有效实时数据"; message.text = "断开或数据过期后清空逐串读数。"
            grid.isHidden = true; return
        }
        let cells = BMSCellSummary(cells: reading.cells)
        grid.isHidden = cells.cells.isEmpty
        if cells.cells.isEmpty {
            summary.text = reading.cellDelta.map { String(format: "设备报告压差 %.0f mV", $0 * 1000) } ?? "当前设备未提供逐串电压"
            message.text = "\(reading.family.title) 当前数据没有逐串明细。"; return
        }
        let low = cells.minimum.map { String(format: "%.3f V", $0) } ?? "--"
        let high = cells.maximum.map { String(format: "%.3f V", $0) } ?? "--"
        let delta = cells.delta.map { String(format: "%.0f mV", $0 * 1000) } ?? "--"
        summary.text = "最低 \(low) · 最高 \(high)\n逐串压差 \(delta) · 有效 \(cells.validCount)/\(cells.cells.count) 串"
        message.text = "最高、最低单体以文字标记；缺失数据保留原串号。"
        for (index, labels) in cellLabels.enumerated() where cells.cells.indices.contains(index) {
            let (_, value, marker, tile) = labels
            let voltage = cells.cells[index]
            value.text = voltage.map { String(format: "%.3f V", $0) } ?? "--"
            let isLow = cells.validCount >= 2 && cells.minimum != cells.maximum && voltage != nil && voltage == cells.minimum
            let isHigh = cells.validCount >= 2 && cells.minimum != cells.maximum && voltage != nil && voltage == cells.maximum
            let text = voltage == nil ? "未读到" : isLow ? "最低" : isHigh ? "最高" : "单体电压"
            marker.text = text
            tile.backgroundColor = isLow ? UIColor.systemOrange.withAlphaComponent(0.12) : isHigh ? UIColor.systemBlue.withAlphaComponent(0.12) : .tertiarySystemFill
            value.textColor = voltage == nil ? .secondaryLabel : .label
            tile.accessibilityLabel = "第 \(index + 1) 串"
            tile.accessibilityValue = (value.text ?? "--") + "，" + text
        }
    }
}
