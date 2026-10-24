import AppKit

final class QuotaView: NSView {
    private let stack = NSStackView()
    private let attentionLabel = NSTextField(labelWithString: "")
    private let primaryRow = QuotaRowView(title: "5小时")
    private let secondaryRow = QuotaRowView(title: "周限额")
    private let errorLabel = NSTextField(labelWithString: "")
    private let showsClaude: Bool
    private let codexHeader = NSTextField(labelWithString: "Codex")
    private let claudeSeparator = NSBox()
    private let claudeHeader = NSTextField(labelWithString: "Claude Code")
    private let claudePrimaryRow = QuotaRowView(title: "5小时")
    private let claudeSecondaryRow = QuotaRowView(title: "周限额")
    private let claudeErrorLabel = NSTextField(labelWithString: "")

    init(frame frameRect: NSRect, showsClaude: Bool) {
        self.showsClaude = showsClaude
        super.init(frame: frameRect)
        setup()
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, showsClaude: false)
    }

    required init?(coder: NSCoder) {
        showsClaude = false
        super.init(coder: coder)
        setup()
    }

    func updateClaude(_ model: ClaudeDisplayModel) {
        claudePrimaryRow.update(model.primary)
        claudeSecondaryRow.update(model.secondary)
        claudeErrorLabel.stringValue = model.error ?? ""
        claudeErrorLabel.isHidden = model.error == nil
    }

    func update(_ model: QuotaDisplayModel) {
        attentionLabel.stringValue = model.attention.message ?? ""
        attentionLabel.isHidden = !model.attention.needsUserAction
        primaryRow.update(model.primary)
        primaryRow.isHidden = !model.primary.hasValue
        secondaryRow.update(model.secondary)
        secondaryRow.isHidden = !model.secondary.hasValue
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

        if showsClaude {
            for header in [codexHeader, claudeHeader] {
                header.font = .systemFont(ofSize: 11, weight: .medium)
                header.textColor = .secondaryLabelColor
            }
            stack.addArrangedSubview(codexHeader)
        }
        stack.addArrangedSubview(attentionLabel)
        stack.addArrangedSubview(primaryRow)
        stack.addArrangedSubview(secondaryRow)
        stack.addArrangedSubview(errorLabel)

        if showsClaude {
            claudeSeparator.boxType = .separator
            claudeErrorLabel.font = .systemFont(ofSize: 10)
            claudeErrorLabel.textColor = .secondaryLabelColor
            claudeErrorLabel.lineBreakMode = .byTruncatingTail
            claudeErrorLabel.isHidden = true

            stack.addArrangedSubview(claudeSeparator)
            stack.addArrangedSubview(claudeHeader)
            stack.addArrangedSubview(claudePrimaryRow)
            stack.addArrangedSubview(claudeSecondaryRow)
            stack.addArrangedSubview(claudeErrorLabel)
            claudeSeparator.widthAnchor.constraint(equalToConstant: 294).isActive = true
        }

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
            valueLabel.widthAnchor.constraint(equalToConstant: 124)
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
