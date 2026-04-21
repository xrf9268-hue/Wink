import AppKit

@MainActor
final class MenuBarShortcutRowView: NSView {
    static let contentLeadingInset: CGFloat = 18
    static let contentTrailingInset: CGFloat = 16
    static let contentVerticalInset: CGFloat = 6

    let presentation: MenuBarShortcutItemPresentation

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let runningDot = NSView()
    private let warningImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var iconWidthConstraint: NSLayoutConstraint?

    var renderedTitleColor: NSColor { titleLabel.textColor ?? .labelColor }
    var renderedShortcutColor: NSColor { shortcutLabel.textColor ?? .secondaryLabelColor }
    var renderedStatusText: String { statusLabel.stringValue }
    var isStatusLabelHidden: Bool { statusLabel.isHidden }
    var isRunningDotHidden: Bool { runningDot.isHidden }
    var isWarningHidden: Bool { warningImageView.isHidden }
    var renderedToolTip: String? { toolTip }

    init(presentation: MenuBarShortcutItemPresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        setupView()
        applyPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 336, height: 32)
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView()
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 6
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        runningDot.translatesAutoresizingMaskIntoConstraints = false
        runningDot.wantsLayer = true
        runningDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        runningDot.layer?.cornerRadius = 3.5
        runningDot.setContentCompressionResistancePriority(.required, for: .horizontal)

        warningImageView.translatesAutoresizingMaskIntoConstraints = false
        warningImageView.imageScaling = .scaleProportionallyUpOrDown
        warningImageView.contentTintColor = .systemOrange
        warningImageView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "App unavailable"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        warningImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        shortcutLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcutLabel.alignment = .right
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)

        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(runningDot)
        titleStack.addArrangedSubview(warningImageView)
        titleStack.addArrangedSubview(statusLabel)

        let rootStack = NSStackView()
        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.detachesHiddenViews = true

        rootStack.addArrangedSubview(iconView)
        rootStack.addArrangedSubview(titleStack)
        rootStack.addArrangedSubview(NSView())
        rootStack.addArrangedSubview(shortcutLabel)

        addSubview(rootStack)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 18)

        NSLayoutConstraint.activate([
            iconWidthConstraint,
            iconView.heightAnchor.constraint(equalToConstant: 18),
            runningDot.widthAnchor.constraint(equalToConstant: 7),
            runningDot.heightAnchor.constraint(equalToConstant: 7),
            warningImageView.widthAnchor.constraint(equalToConstant: 11),
            warningImageView.heightAnchor.constraint(equalToConstant: 11),
            rootStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.contentLeadingInset
            ),
            rootStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.contentTrailingInset
            ),
            rootStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.contentVerticalInset
            ),
            rootStack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Self.contentVerticalInset
            ),
        ].compactMap { $0 })
    }

    private func applyPresentation() {
        titleLabel.stringValue = presentation.titleText
        statusLabel.stringValue = presentation.statusText ?? ""
        statusLabel.isHidden = presentation.statusText == nil
        runningDot.isHidden = !presentation.isRunning
        warningImageView.isHidden = !presentation.isUnavailable
        shortcutLabel.stringValue = presentation.shortcutText ?? ""
        shortcutLabel.isHidden = presentation.shortcutText == nil
        toolTip = presentation.unavailableHelpText

        if presentation.isPlaceholder {
            iconView.image = nil
            iconView.isHidden = true
            iconWidthConstraint?.constant = 0
            titleLabel.textColor = .tertiaryLabelColor
            shortcutLabel.textColor = .tertiaryLabelColor
            return
        }

        iconView.isHidden = false
        iconWidthConstraint?.constant = 18
        iconView.image = resolvedIcon(for: presentation.bundleIdentifier)

        let isDimmed = !presentation.isEnabled || presentation.isUnavailable
        titleLabel.textColor = isDimmed ? .secondaryLabelColor : .labelColor
        shortcutLabel.textColor = isDimmed ? .tertiaryLabelColor : .secondaryLabelColor
        statusLabel.textColor = isDimmed ? .tertiaryLabelColor : .secondaryLabelColor
        iconView.alphaValue = isDimmed ? 0.6 : 1.0
    }

    private func resolvedIcon(for bundleIdentifier: String?) -> NSImage {
        guard
            let bundleIdentifier,
            let icon = AppIconCache.icon(for: bundleIdentifier)
        else {
            return Self.fallbackIcon
        }

        return icon
    }

    private static let fallbackIcon = NSWorkspace.shared.icon(for: .application)
}
