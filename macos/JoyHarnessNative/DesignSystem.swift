import SwiftUI

enum JoyTheme {
    static let blue = Color(red: 0.12, green: 0.49, blue: 0.96)
    static let red = Color(red: 1.0, green: 0.28, blue: 0.20)
    static let green = Color(red: 0.16, green: 0.72, blue: 0.42)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)

    // 键帽。按键页上那一颗颗圆形/胶囊画的是实体按键，深浅模式下都保持
    // 深色，只在明度上差一档 —— 这两个值原来散在 MappingView 里，
    // 是全客户端仅剩的两处自定义色值。
    static let keyCap = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let keyCapRaised = Color(red: 0.27, green: 0.27, blue: 0.29)

    /// A key cap drawn on a grouped-list row rather than on the 按键 page's
    /// light card. The dark cap all but disappears against a dark-mode row, so
    /// this one lightens instead of staying fixed.
    static let keyCapOnRow = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.33, green: 0.33, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
    })

    /// The second line of a row -- battery, an explanation under a title, the
    /// meaning of a shortcut. `.secondary` is about 50% opacity, which at the
    /// sizes this app uses reads as visible but not quite legible; this is the
    /// same role one step stronger.
    static let detail = Color.primary.opacity(0.64)

    /// The surface a card is drawn on. Deliberately opaque: `.regularMaterial`
    /// let the window background through, and every label on a translucent
    /// card lost contrast against it -- the reason the whole app read as
    /// slightly out of focus.
    static let cardSurface = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color.primary.opacity(0.1)

    static let sidebarWidth: CGFloat = 232
}

/// Spacing scale used across pages so paddings/gaps stay consistent instead
/// of ad hoc magic numbers per view. Roughly a 4pt-based scale.
enum JoySpacing {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 30
    /// Standard outer padding for a full page (ConnectionView, PermissionsView, ...).
    static let pagePadding: CGFloat = 30
}

/// Shared motion tokens. Using one small set of durations/curves (instead of
/// each view picking its own) is what makes hover, press and state-change
/// feedback read as one consistent system rather than a pile of one-offs.
enum JoyMotion {
    /// Hover / focus affordances (buttons, cards).
    static let hover = Animation.easeOut(duration: 0.15)
    /// Press-down feedback.
    static let press = Animation.easeOut(duration: 0.1)
    /// A page-level state changing (e.g. availability, permission status).
    static let stateChange = Animation.easeInOut(duration: 0.22)
    /// Multi-step flows advancing (onboarding).
    static let stepTransition = Animation.easeInOut(duration: 0.28)
}

struct JoyCard<Content: View>: View {
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(JoyTheme.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(JoyTheme.cardBorder, lineWidth: 1)
            }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct ConnectionStatusBadge: View {
    let availability: AvailabilityState

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .imageScale(.small)
            Text(availability.badge)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12))
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前状态：\(availability.badge)")
    }

    private var tint: Color { Color(nsColor: availability.tint) }

    private var iconName: String {
        switch availability {
        case .serviceStopped: return "exclamationmark.triangle.fill"
        case .permissionRequired: return "lock.trianglebadge.exclamationmark"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .paused: return "pause.circle.fill"
        case .ready: return "checkmark.circle.fill"
        }
    }
}

struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @State private var isSpinning = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(IconButtonStyle())
        .disabled(isRefreshing)
        .help("重新检测")
        .accessibilityLabel("重新检测")
        .onChange(of: isRefreshing) { refreshing in
            if refreshing {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    isSpinning = false
                }
            }
        }
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var trailing: AnyView?

    init(_ title: String, subtitle: String, trailing: AnyView? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(JoyTheme.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            trailing
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.55))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(JoyTheme.blue.opacity(isEnabled ? (configuration.isPressed ? 0.72 : (isHovering ? 0.9 : 1)) : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovering && isEnabled ? 1.01 : 1))
            .shadow(color: isHovering && isEnabled ? JoyTheme.blue.opacity(0.2) : .clear, radius: 5, y: 2)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.14 : (isHovering ? 0.1 : 0.06)) : 0.035))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(isEnabled && isHovering ? 0.16 : 0.08), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovering && isEnabled ? 1.01 : 1))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.78 : 0.35))
            .frame(width: 34, height: 34)
            .background(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.15 : (isHovering ? 0.1 : 0.06)) : 0.035))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(isEnabled && isHovering ? 0.16 : 0.08), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : (isHovering && isEnabled ? 1.04 : 1))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct InfoRow: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = JoyTheme.blue
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(JoyTheme.detail)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// The label above a section, with an optional action on the right. The action
/// is a link rather than a bordered button: a section header should not compete
/// with the page's real buttons for attention.
struct JoySectionHeader: View {
    let title: String
    var trailing: AnyView?

    init(_ title: String, trailing: AnyView? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 3)
    }
}

/// Named with a Joy prefix because SwiftUI already ships a `LinkButtonStyle`.
struct JoyLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(JoyTheme.blue.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4))
            .underline(isHovering && isEnabled)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(JoyMotion.hover, value: isHovering)
    }
}
