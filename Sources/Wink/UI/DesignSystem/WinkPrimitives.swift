import SwiftUI

// MARK: - Card

/// Grouped container with optional title row + accessory. Mirrors the
/// `WinkCard` shape used across the v2 settings and menu bar surfaces.
struct WinkCard<Title: View, Accessory: View, Content: View>: View {
    @Environment(\.winkPalette) private var palette
    @ViewBuilder var title: () -> Title
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Title.self != EmptyView.self || Accessory.self != EmptyView.self {
                HStack(alignment: .center, spacing: 8) {
                    title()
                        .font(WinkType.cardTitle)
                        .foregroundStyle(palette.textPrimary)
                    Spacer(minLength: 8)
                    accessory()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
                Divider().overlay(palette.hairline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardBg)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.cardBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(
            color: palette.cardShadowColor,
            radius: palette.cardShadowRadius,
            y: palette.cardShadowY
        )
    }
}

extension WinkCard where Title == EmptyView, Accessory == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(title: { EmptyView() }, accessory: { EmptyView() }, content: content)
    }
}

extension WinkCard where Accessory == EmptyView {
    init(@ViewBuilder title: @escaping () -> Title, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Banner

enum WinkBannerKind: Sendable, Hashable {
    case info, success, warn, error
}

/// Permission / nudge banner. Mirrors `Banner` in `wink/project/v2/chrome.jsx`.
struct WinkBanner<Trailing: View>: View {
    @Environment(\.winkPalette) private var palette
    let kind: WinkBannerKind
    let title: String
    let message: String?
    var icon: String?
    @ViewBuilder var trailing: () -> Trailing

    init(
        kind: WinkBannerKind,
        title: String,
        message: String? = nil,
        icon: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.icon = icon
        self.trailing = trailing
    }

    private var style: (background: Color, foreground: Color, systemImage: String) {
        let base: (background: Color, foreground: Color, systemImage: String)
        switch kind {
        case .success: base = (palette.greenSoft,    palette.green, "checkmark.circle.fill")
        case .info:    base = (palette.accentBgSoft, palette.accent, "info.circle.fill")
        case .warn:    base = (palette.amberBgSoft,  palette.amber, "exclamationmark.triangle.fill")
        case .error:   base = (palette.redBgSoft,    palette.red,   "exclamationmark.octagon.fill")
        }
        return (base.background, base.foreground, icon ?? base.systemImage)
    }

    var body: some View {
        let s = style
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(s.foreground)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(s.foreground)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(s.background)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(s.foreground.opacity(0.2), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Convenience initializer for banners without a trailing accessory.
extension WinkBanner where Trailing == EmptyView {
    init(kind: WinkBannerKind, title: String, message: String? = nil, icon: String? = nil) {
        self.init(kind: kind, title: title, message: message, icon: icon) { EmptyView() }
    }
}

// MARK: - Section label

struct WinkSectionLabel: View {
    @Environment(\.winkPalette) private var palette
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(WinkType.sectionLabel)
            .foregroundStyle(palette.textTertiary)
            .tracking(0.6)
    }
}

// MARK: - Keycap

/// Native-style keycap pill for shortcut glyphs.
struct WinkKeycap: View {
    enum Size { case small, medium }

    @Environment(\.winkPalette) private var palette
    let label: String
    var size: Size = .medium

    init(_ label: String, size: Size = .medium) {
        self.label = label
        self.size = size
    }

    var body: some View {
        let height: CGFloat = (size == .small) ? 18 : 20
        let font: Font = (size == .small) ? .system(size: 11, weight: .medium) : .system(size: 12, weight: .medium)
        Text(label)
            .font(font)
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 5)
            .frame(minWidth: height, minHeight: height)
            .background(palette.controlBgRest)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(palette.controlBorder, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Shortcut glyph

/// Plain-text accelerator glyph — mirrors `ShortcutGlyph` in `primitives.jsx`.
/// Menu-native contexts (the menu bar popover) render key combos as tight,
/// unstyled text rather than the boxed `WinkKeycap` pills used in the
/// Shortcuts tab's list.
struct WinkShortcutGlyph: View {
    @Environment(\.winkPalette) private var palette
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(WinkType.bodyMedium)
            .tracking(0.5)
            .foregroundStyle(palette.textSecondary)
    }
}

// MARK: - Hyper badge

struct WinkHyperBadge: View {
    enum Size { case small, medium }
    @Environment(\.winkPalette) private var palette
    var size: Size = .medium

    var body: some View {
        let height: CGFloat = (size == .small) ? 15 : 17
        let font: Font = (size == .small)
            ? .system(size: 9.5, weight: .bold)
            : .system(size: 10.5, weight: .bold)
        // `verbatim` for the same reason the wordmark uses it: a bare literal
        // is a LocalizedStringKey, and "Hyper" is a product term that stays
        // Latin in every locale (see `WinkWordmark`).
        Text(verbatim: "HYPER")
            .font(font)
            .tracking(0.4)
            .lineLimit(1)
            // Same rule as the combo badge next to it: never yield to row
            // compression — "HYPE / R" on two lines is not a badge (#409).
            .fixedSize()
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 6)
            .frame(minHeight: height)
            .background(palette.accentBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Status dot

struct WinkStatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        // Mirrors the CSS spread box-shadow `0 0 0 2px ${color}22`, which sits
        // entirely outside the dot's box — a stroke on the dot's own edge
        // would halve the halo instead of extending past it.
        Circle()
            .fill(color.opacity(0.13))
            .frame(width: size + 4, height: size + 4)
            .overlay(
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
            )
    }
}

// MARK: - Switch

/// A native-feeling toggle switch sized to the v2 spec. The standard
/// SwiftUI `Toggle(.switch)` doesn't quite match the menu bar density,
/// so we draw our own — but route accessibility through a real `Toggle`
/// via `.accessibilityRepresentation` so VoiceOver announces the
/// "switch, on/off" role and Space-bar still toggles.
struct WinkSwitch: View {
    enum Size { case small, medium }

    @Environment(\.winkPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isOn: Bool
    var size: Size = .medium

    private var track: (width: CGFloat, height: CGFloat, knob: CGFloat, inset: CGFloat) {
        switch size {
        case .small:  return (28, 16, 12, 2)
        case .medium: return (36, 22, 18, 2)
        }
    }

    private var trackOffColor: Color {
        colorScheme == .dark
            ? .winkSRGB(0x48, 0x48, 0x4A)
            : .winkSRGB(0xD4, 0xD4, 0xD4)
    }

    var body: some View {
        let dims = track
        let knobTravel = dims.width - dims.knob - (dims.inset * 2)

        Button(action: { isOn.toggle() }) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: dims.height / 2)
                    .fill(isOn ? palette.accent : trackOffColor)
                    .frame(width: dims.width, height: dims.height)

                Circle()
                    .fill(Color.white)
                    .frame(width: dims.knob, height: dims.knob)
                    .shadow(color: .winkBlack(0.25), radius: 1, y: 1)
                    .padding(.leading, dims.inset)
                    .offset(x: isOn ? knobTravel : 0)
            }
            .animation(.easeInOut(duration: 0.18), value: isOn)
            .contentShape(RoundedRectangle(cornerRadius: dims.height / 2))
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - Segmented

struct WinkSegmented<Value: Hashable>: View {
    @Environment(\.winkPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    let accessibilityLabel: String?

    init(
        options: [(label: String, value: Value)],
        selection: Binding<Value>,
        accessibilityLabel: String? = nil
    ) {
        self.options = options
        self._selection = selection
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                Button(action: { selection = option.value }) {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? palette.textPrimary : palette.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active
                                    ? (colorScheme == .dark
                                        ? Color.winkWhite(0.14)
                                        : Color.winkSRGB(0xFF, 0xFF, 0xFF))
                                    : .clear)
                                .shadow(color: active ? .winkBlack(0.12) : .clear, radius: 1, y: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colorScheme == .dark ? Color.winkWhite(0.06) : Color.winkSRGB(0x3C, 0x3C, 0x43, 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(colorScheme == .dark ? Color.winkWhite(0.08) : Color.winkBlack(0.08), lineWidth: 0.5)
        )
        .accessibilityRepresentation {
            Picker(selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                Text(accessibilityLabel ?? "")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

// MARK: - Button

enum WinkButtonVariant: Sendable {
    case primary, secondary, ghost, danger
}

/// The two control heights the design system uses. `small` is the toolbar
/// row (buttons that sit beside a title); `medium` is the form-field row,
/// which every field in the New Shortcut card already draws at 28.
///
/// Shared so a button and the dropdown beside it cannot drift apart.
enum WinkControlSize: Sendable {
    case small, medium

    var height: CGFloat {
        switch self {
        case .small: return 24
        case .medium: return 28
        }
    }
}

/// A button's visual body, without the button. Split out so `WinkMenuButton`
/// can wear the identical chrome instead of copying its metrics.
struct WinkButtonLabel: View {
    @Environment(\.winkPalette) private var palette
    let label: String
    var variant: WinkButtonVariant = .secondary
    var size: WinkControlSize = .small
    var systemImage: String?
    /// Draws the trailing disclosure chevron a menu trigger needs.
    var showsMenuIndicator: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size == .small ? 11 : 12, weight: .medium))
            }
            Text(label)
                .font(.system(size: size == .small ? 12 : 13, weight: .medium))
            if showsMenuIndicator {
                WinkIcon.chevronDown.image(size: size == .small ? 9 : 10)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(.horizontal, size == .small ? 11 : 14)
        .frame(height: size.height)
        .foregroundStyle(foreground)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var foreground: Color {
        switch variant {
        case .primary: return palette.textOnAccent
        case .secondary: return palette.textPrimary
        case .ghost: return palette.textPrimary
        case .danger: return palette.red
        }
    }

    private var background: Color {
        switch variant {
        case .primary: return palette.accent
        case .secondary: return palette.controlBg
        case .ghost: return .clear
        case .danger: return palette.redBgSoft
        }
    }

    private var border: Color {
        switch variant {
        case .primary: return .clear
        case .secondary: return palette.controlBorder
        case .ghost: return .clear
        case .danger: return palette.redBorderSoft
        }
    }
}

struct WinkButton: View {
    typealias Size = WinkControlSize

    let label: String
    var variant: WinkButtonVariant = .secondary
    var size: Size = .small
    let systemImage: String?
    let action: () -> Void

    init(
        _ label: String,
        variant: WinkButtonVariant = .secondary,
        size: Size = .small,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.variant = variant
        self.size = size
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            WinkButtonLabel(
                label: label,
                variant: variant,
                size: size,
                systemImage: systemImage
            )
        }
        .buttonStyle(.plain)
    }
}

/// A `WinkButton` that opens a menu instead of firing an action — for
/// "Add Profile"-style triggers, where the control is a button that happens to
/// offer choices, not a field showing the current one (that is `WinkMenuField`).
///
/// See `WinkMenuField` for why the modifier stack is what it is.
struct WinkMenuButton<Content: View>: View {
    let label: String
    var variant: WinkButtonVariant = .secondary
    var size: WinkControlSize = .small
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    init(
        _ label: String,
        variant: WinkButtonVariant = .secondary,
        size: WinkControlSize = .small,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.variant = variant
        self.size = size
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            WinkButtonLabel(
                label: label,
                variant: variant,
                size: size,
                systemImage: systemImage,
                showsMenuIndicator: true
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - Menu field (dropdown)

/// The chrome every Wink dropdown wears, without the trigger.
///
/// A stock `Picker`/`Menu` renders as an `NSPopUpButton`: system height,
/// system corner radius, and a chevron well filled with the *system* accent.
/// Wink's accent is amber (see `DesignTokens`), so a stock control is the one
/// place in the window that paints system blue, and its ~22pt height never
/// lines up with the 28pt fields beside it. Draw this instead.
///
/// Split from `WinkMenuField` because not every dropdown is a `Menu`: the
/// target-app field opens a searchable `AppPickerPopover` from a `Button` and
/// needs the same chrome around a different trigger.
struct WinkMenuFieldLabel<Leading: View>: View {
    @Environment(\.winkPalette) private var palette

    let title: String
    var isPlaceholder: Bool = false
    var size: WinkControlSize = .medium
    @ViewBuilder var leading: () -> Leading

    init(
        _ title: String,
        isPlaceholder: Bool = false,
        size: WinkControlSize = .medium,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }
    ) {
        self.title = title
        self.isPlaceholder = isPlaceholder
        self.size = size
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: 8) {
            leading()

            Text(title)
                .font(WinkType.bodyText)
                .foregroundStyle(isPlaceholder ? palette.textTertiary : palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            WinkIcon.chevronDown.image(size: 11)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: size.height)
        .background(palette.controlBg)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(palette.controlBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The common case: a `Menu` wearing `WinkMenuFieldLabel`.
///
/// All three modifiers are load-bearing, and the tempting
/// `.menuStyle(.borderlessButton)` used elsewhere in the app is **not** one of
/// them — that style measures itself rather than its label, reporting 70×16
/// for a 96×28 field, so the chrome gets drawn at a size the layout never
/// reserved. `.menuStyle(.button)` adopts the label's geometry exactly, and
/// `.buttonStyle(.plain)` strips the bezel that style would otherwise draw
/// behind it. `.buttonStyle(.plain)` *without* an explicit menu style also
/// measures correctly but silently stops responding to clicks, so keep the
/// pair together. `.menuIndicator(.hidden)` then suppresses the system
/// chevron, which would otherwise sit beside the one the label draws.
struct WinkMenuField<Leading: View, Content: View>: View {
    let title: String
    var isPlaceholder: Bool = false
    var size: WinkControlSize = .medium
    @ViewBuilder var content: () -> Content
    @ViewBuilder var leading: () -> Leading

    init(
        _ title: String,
        isPlaceholder: Bool = false,
        size: WinkControlSize = .medium,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }
    ) {
        self.title = title
        self.isPlaceholder = isPlaceholder
        self.size = size
        self.content = content
        self.leading = leading
    }

    var body: some View {
        Menu {
            content()
        } label: {
            WinkMenuFieldLabel(
                title,
                isPlaceholder: isPlaceholder,
                size: size,
                leading: leading
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }
}

// MARK: - Text field (display-only)

/// A non-editable presentational field used for popover search placeholders
/// and filter chips. The actual `TextField` interaction lives in the
/// consuming view; this primitive only owns the chrome.
struct WinkTextField<Leading: View, Trailing: View>: View {
    @Environment(\.winkPalette) private var palette
    let placeholder: String
    @Binding var text: String
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(
        placeholder: String,
        text: Binding<String>,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.placeholder = placeholder
        self._text = text
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            leading()
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.textPrimary)
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 22)
        .background(palette.fieldBg)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(palette.fieldBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Icon glyph helpers

/// SF Symbol mapping for the 16 icons in `wink/project/v2/primitives.jsx`.
/// Apple's HIG recommends SF Symbols over hand-rolled SVGs whenever possible
/// for legibility, color contexts, and reduced-motion support.
enum WinkIcon: String, CaseIterable, Sendable {
    case keyboard, gear, chart, sparkles, search, plus, close, more
    case chevronRight, chevronDown, grip, info, warn, check, record
    case pause, play, flame, refresh, clock, arrowUp, arrowDown
    case app, lock

    var systemName: String {
        switch self {
        case .keyboard:     return "keyboard"
        case .gear:         return "gearshape"
        case .chart:        return "chart.bar"
        case .sparkles:     return "sparkles"
        case .search:       return "magnifyingglass"
        case .plus:         return "plus"
        case .close:        return "xmark"
        case .more:         return "ellipsis"
        case .chevronRight: return "chevron.right"
        case .chevronDown:  return "chevron.down"
        case .grip:         return "line.3.horizontal"
        case .info:         return "info.circle"
        case .warn:         return "exclamationmark.triangle"
        case .check:        return "checkmark.circle"
        case .record:       return "record.circle"
        case .pause:        return "pause.fill"
        case .play:         return "play.fill"
        case .flame:        return "flame"
        case .refresh:      return "arrow.clockwise"
        case .clock:        return "clock"
        case .arrowUp:      return "arrow.up"
        case .arrowDown:    return "arrow.down"
        case .app:          return "square.grid.2x2"
        case .lock:         return "lock"
        }
    }

    func image(size: CGFloat = 12, weight: Font.Weight = .medium) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
    }
}
