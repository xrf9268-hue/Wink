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
    @ViewBuilder var trailing: () -> Trailing

    init(
        kind: WinkBannerKind,
        title: String,
        message: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.trailing = trailing
    }

    private var palette_: (background: Color, foreground: Color, systemImage: String) {
        switch kind {
        case .success: return (palette.greenSoft,    palette.green, "checkmark.circle.fill")
        case .info:    return (palette.accentBgSoft, palette.accent, "info.circle.fill")
        case .warn:    return (palette.amberBgSoft,  palette.amber, "exclamationmark.triangle.fill")
        case .error:   return (palette.redBgSoft,    palette.red,   "exclamationmark.octagon.fill")
        }
    }

    var body: some View {
        let p = palette_
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: p.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(p.foreground)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.foreground)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if Trailing.self != EmptyView.self {
                Spacer(minLength: 8)
                trailing()
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(p.background)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(p.foreground.opacity(0.2), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        Text("HYPER")
            .font(font)
            .tracking(0.4)
            .foregroundStyle(palette.violet)
            .padding(.horizontal, 6)
            .frame(minHeight: height)
            .background(palette.violetBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Status dot

struct WinkStatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.13), lineWidth: 2)
            )
    }
}

// MARK: - Switch

/// A native-feeling toggle switch sized to the v2 spec. The standard
/// SwiftUI `Toggle(.switch)` doesn't quite match the menu bar density, so
/// we draw our own when the visual matters.
struct WinkSwitch: View {
    enum Size { case small, medium }

    @Environment(\.winkPalette) private var palette
    @Binding var isOn: Bool
    var size: Size = .medium

    private var track: (width: CGFloat, height: CGFloat, knob: CGFloat) {
        switch size {
        case .small:  return (28, 16, 12)
        case .medium: return (36, 22, 18)
        }
    }

    private var trackOff: Color {
        Color.winkSRGB(0xD4, 0xD4, 0xD4)
    }
    private var trackOffDark: Color {
        Color.winkSRGB(0x48, 0x48, 0x4A)
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dims = track
        Button(action: { isOn.toggle() }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: dims.height / 2)
                    .fill(isOn ? palette.accent : (colorScheme == .dark ? trackOffDark : trackOff))
                    .frame(width: dims.width, height: dims.height)

                Circle()
                    .fill(Color.white)
                    .frame(width: dims.knob, height: dims.knob)
                    .shadow(color: .winkBlack(0.25), radius: 1, y: 1)
                    .padding(.horizontal, 2)
            }
            .animation(.easeInOut(duration: 0.18), value: isOn)
            .contentShape(RoundedRectangle(cornerRadius: dims.height / 2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Segmented

struct WinkSegmented<Value: Hashable>: View {
    @Environment(\.winkPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

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
    }
}

// MARK: - Button

enum WinkButtonVariant: Sendable {
    case primary, secondary, ghost, danger
}

struct WinkButton: View {
    enum Size { case small, medium }

    @Environment(\.winkPalette) private var palette
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
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size == .small ? 11 : 12, weight: .medium))
                }
                Text(label)
                    .font(.system(size: size == .small ? 12 : 13, weight: .medium))
            }
            .padding(.horizontal, size == .small ? 11 : 14)
            .frame(height: size == .small ? 24 : 28)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
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
