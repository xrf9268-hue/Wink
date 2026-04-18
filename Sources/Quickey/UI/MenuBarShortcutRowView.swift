import AppKit

final class MenuBarShortcutRowView: NSView {
    let presentation: MenuBarShortcutItemPresentation

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let runningDot = NSView()
    private let shortcutLabel = NSTextField(labelWithString: "")

    init(presentation: MenuBarShortcutItemPresentation) {
        self.presentation = presentation
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        translatesAutoresizingMaskIntoConstraints = false
        setupView()
        applyPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 42)
    }

    var renderedTitleColor: NSColor { titleLabel.textColor ?? .labelColor }
    var renderedShortcutColor: NSColor { shortcutLabel.textColor ?? .secondaryLabelColor }
    var renderedIconAlpha: CGFloat { iconView.alphaValue }

    private func setupView() {
        let leadingStack = NSStackView()
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 10
        leadingStack.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        runningDot.translatesAutoresizingMaskIntoConstraints = false
        runningDot.wantsLayer = true
        runningDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        runningDot.layer?.cornerRadius = 3

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.cell?.lineBreakMode = .byTruncatingTail

        shortcutLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(runningDot)
        textStack.addArrangedSubview(titleRow)
        textStack.addArrangedSubview(statusLabel)

        leadingStack.addArrangedSubview(iconView)
        leadingStack.addArrangedSubview(textStack)

        addSubview(leadingStack)
        addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            runningDot.widthAnchor.constraint(equalToConstant: 6),
            runningDot.heightAnchor.constraint(equalToConstant: 6),

            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            leadingStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingStack.trailingAnchor, constant: 12),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func applyPresentation() {
        titleLabel.stringValue = presentation.titleText
        statusLabel.stringValue = presentation.statusText ?? ""
        statusLabel.isHidden = presentation.statusText == nil
        runningDot.isHidden = !presentation.isRunning
        shortcutLabel.stringValue = presentation.shortcutText ?? ""
        shortcutLabel.isHidden = presentation.shortcutText == nil

        if presentation.isEnabled {
            titleLabel.textColor = .labelColor
            shortcutLabel.textColor = .secondaryLabelColor
            iconView.alphaValue = 1.0
        } else {
            titleLabel.textColor = .disabledControlTextColor
            shortcutLabel.textColor = .disabledControlTextColor
            iconView.alphaValue = 0.5
        }

        let icon = if let bundleIdentifier = presentation.bundleIdentifier {
            AppIconCache.icon(for: bundleIdentifier) ?? Self.fallbackIcon
        } else {
            Self.fallbackIcon
        }
        iconView.image = icon
    }

    private static let fallbackIcon = NSWorkspace.shared.icon(for: .application)
}
