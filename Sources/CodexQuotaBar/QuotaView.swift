import AppKit

final class QuotaView: NSView {
    private let stack = NSStackView()
    private let attentionLabel = NSTextField(labelWithString: "")
    private let primaryRow = QuotaRowView(title: "5小时")
    private let secondaryRow = QuotaRowView(title: "周限额")
    private let errorLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(_ model: QuotaDisplayModel) {
        attentionLabel.stringValue = model.attention.message ?? ""
        attentionLabel.isHidden = !model.attention.needsUserAction
        primaryRow.update(model.primary)
        secondaryRow.update(model.secondary)
        errorLabel.stringValue = model.error ?? ""
        errorLabel.isHidden = model.error == nil
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        errorLabel.font = .systemFont(ofSize: 10)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.lineBreakMode = .byTruncatingTail

        attentionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        attentionLabel.textColor = .systemOrange
        attentionLabel.lineBreakMode = .byTruncatingTail
        attentionLabel.isHidden = true

        stack.addArrangedSubview(attentionLabel)
        stack.addArrangedSubview(primaryRow)
        stack.addArrangedSubview(secondaryRow)
        stack.addArrangedSubview(errorLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

final class QuotaRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bar = SegmentedBatteryView()
    private let valueLabel = NSTextField(labelWithString: "")

    init(title: String) {
        titleLabel.stringValue = title
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(_ model: WindowDisplay) {
        titleLabel.stringValue = model.title
        bar.remainingPercent = model.remaining
        valueLabel.stringValue = "\(model.remainingText)  \(model.resetText)"
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(bar)
        addSubview(valueLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 44),

            bar.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 12),

            valueLabel.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 96)
        ])
    }
}

final class SegmentedBatteryView: NSView {
    var remainingPercent: Int? {
        didSet { needsDisplay = true }
    }

    private let segments = 10

    override var intrinsicContentSize: NSSize {
        NSSize(width: 110, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let percent = remainingPercent ?? 0
        let filledSegments = Int(ceil(Double(max(0, min(100, percent))) / 10.0))
        let gap: CGFloat = 2
        let segmentWidth = (bounds.width - CGFloat(segments - 1) * gap) / CGFloat(segments)

        for index in 0..<segments {
            let rect = NSRect(
                x: CGFloat(index) * (segmentWidth + gap),
                y: 0,
                width: segmentWidth,
                height: bounds.height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            let isFilled = index < filledSegments && remainingPercent != nil
            (isFilled ? color(for: percent) : NSColor.separatorColor.withAlphaComponent(0.45)).setFill()
            path.fill()
        }
    }

    private func color(for percent: Int) -> NSColor {
        switch percent {
        case 0..<20:
            return .systemRed
        case 20..<45:
            return .systemOrange
        default:
            return .systemGreen
        }
    }
}
