import SwiftUI
import AppKit
import StudyCore

/// The active theme. Radii and fonts read it directly (views re-render through Observation when it changes);
/// colors resolve through the environment so light and dark follow the view's color scheme.
@Observable
final class ThemeStore {
    nonisolated(unsafe) static let shared = ThemeStore()
    var spec: ThemeSpec = ThemeCatalog.paper
}

private struct ThemeSpecKey: EnvironmentKey { static let defaultValue = ThemeCatalog.paper }

extension EnvironmentValues {
    var themeSpec: ThemeSpec {
        get { self[ThemeSpecKey.self] }
        set { self[ThemeSpecKey.self] = newValue }
    }
}

/// Puts the active theme into the environment of a scene's root view.
struct ThemedRoot: ViewModifier {
    func body(content: Content) -> some View {
        let spec = ThemeStore.shared.spec
        content.environment(\.themeSpec, spec)
    }
}

extension View {
    func themed() -> some View { modifier(ThemedRoot()) }
}

/// A semantic color. Views use these and never a raw color, so any theme restyles the whole app.
struct ThemeColor: ShapeStyle {
    enum Role: Hashable {
        case canvas, surface, surfaceRaised, sidebar, textPrimary, textSecondary, textTertiary, hairline, fillSubtle
        case attention, success, focusRing, clear
        case course(CoursePalette)
    }

    var role: Role
    var alpha: Double = 1

    /// Keeps the type, so `cond ? Theme.attention.opacity(0.1) : Theme.fillSubtle` type-checks.
    func opacity(_ o: Double) -> ThemeColor { ThemeColor(role: role, alpha: alpha * o) }

    func resolve(in environment: EnvironmentValues) -> Color {
        let set = environment.themeSpec.tokens(dark: environment.colorScheme == .dark)
        let token: ColorToken
        switch role {
        case .canvas: token = set.canvas
        case .surface: token = set.surface
        case .surfaceRaised: token = set.surfaceRaised
        case .sidebar: token = set.sidebar
        case .textPrimary: token = set.textPrimary
        case .textSecondary: token = set.textSecondary
        case .textTertiary: token = set.textTertiary
        case .hairline: token = set.hairline
        case .fillSubtle: token = set.fillSubtle
        case .attention: token = set.attention
        case .success: token = set.success
        case .focusRing: token = set.focusRing
        case .course(let p): token = set.course(p)
        case .clear: return .clear
        }
        let c = Theme.color(token)
        return alpha == 1 ? c : c.opacity(alpha)
    }
}

/// §7.1: system font on a 5-step scale, near-black/near-white text, one accent for "needs attention now",
/// muted course colors used only as dots and thin bars. Values come from the active `ThemeSpec`.
enum Theme {
    static let canvas = ThemeColor(role: .canvas)
    static let surface = ThemeColor(role: .surface)
    static let surfaceRaised = ThemeColor(role: .surfaceRaised)
    static let textPrimary = ThemeColor(role: .textPrimary)
    static let textSecondary = ThemeColor(role: .textSecondary)
    static let textTertiary = ThemeColor(role: .textTertiary)
    static let hairline = ThemeColor(role: .hairline)
    static let fillSubtle = ThemeColor(role: .fillSubtle)
    /// Urgency only: overdue, due within 48 h, class within the hour, expired sign-in.
    static let attention = ThemeColor(role: .attention)
    /// A working connection, a finished step.
    static let success = ThemeColor(role: .success)
    static let focusRing = ThemeColor(role: .focusRing)
    static let clear = ThemeColor(role: .clear)

    static func course(_ token: String?) -> ThemeColor {
        ThemeColor(role: .course(CoursePalette(rawValue: token ?? "") ?? .slate))
    }

    static let maxContentWidth: CGFloat = 960

    enum Size { static let xs: CGFloat = 12, s: CGFloat = 14, m: CGFloat = 16, l: CGFloat = 20, xl: CGFloat = 28 }

    static var radiusCard: CGFloat { ThemeStore.shared.spec.radiusCard }
    static var radiusRow: CGFloat { ThemeStore.shared.spec.radiusRow }

    /// A corner radius designed for Paper, scaled to the active theme: 10 and up follow cards, smaller follow rows.
    static func corner(_ paper: CGFloat) -> CGFloat {
        let spec = ThemeStore.shared.spec
        return paper >= 10 ? paper * spec.radiusCard / 10 : paper * spec.radiusRow / 7
    }

    /// 150 ms and 400 ms; both drop to 0 under Reduce Motion.
    static var motionFast: Double { reduceMotion ? 0 : 0.15 }
    static var motionConnect: Double { reduceMotion ? 0 : 0.4 }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func color(_ token: ColorToken) -> Color {
        switch token {
        case .rgba(let c): return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        case .primary(let o): return Color.primary.opacity(o)
        case .system(let s, _):
            switch s {
            case .windowBackground: return Color(nsColor: .windowBackgroundColor)
            case .controlBackground: return Color(nsColor: .controlBackgroundColor)
            case .label: return Color(nsColor: .labelColor)
            case .accent: return Color(nsColor: .controlAccentColor)
            case .green: return Color(nsColor: .systemGreen)
            case .red: return Color(nsColor: .systemRed)
            case .sidebarMaterial: return .clear
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let c = RGBA(hex: hex)
        self.init(red: c.r, green: c.g, blue: c.b)
    }
}

extension Font {
    static var stTitle: Font { themed(Theme.Size.xl, .semibold, heading: true) }
    static var stHeading: Font { themed(Theme.Size.l, .semibold, heading: true) }
    static var stBodyStrong: Font { themed(Theme.Size.m, .medium) }
    static var stBody: Font { themed(Theme.Size.s, .regular) }
    static var stSmall: Font { themed(Theme.Size.xs, .regular) }
    static var stSmallStrong: Font { themed(Theme.Size.xs, .semibold) }

    private static func themed(_ size: CGFloat, _ weight: Font.Weight, heading: Bool = false) -> Font {
        let spec = ThemeStore.shared.spec
        let design: Font.Design
        switch spec.font {
        case .system: design = .default
        case .rounded: design = .rounded
        case .monospaced: design = .monospaced
        case .serifHeadings: design = heading ? .serif : .default
        }
        return .system(size: size, weight: spec.heavierText ? heavier(weight) : weight, design: design)
    }

    private static func heavier(_ w: Font.Weight) -> Font.Weight {
        switch w {
        case .regular: return .medium
        case .medium: return .semibold
        case .semibold: return .bold
        default: return w
        }
    }
}

struct CourseDot: View {
    var color: String?
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(Theme.course(color)).frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct Chip: View {
    var text: String
    var systemImage: String? = nil
    var urgent = false
    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.stSmall).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(urgent ? Theme.attention : Theme.textSecondary)
        .background(RoundedRectangle(cornerRadius: Theme.corner(4)).fill(urgent ? Theme.attention.opacity(0.1) : Theme.fillSubtle))
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.stSmallStrong).foregroundStyle(Theme.textTertiary).kerning(0.6)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.bottom, 4)
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.hairline))
    }
}

/// One sentence and one action (§7.1 empty states).
struct EmptyState: View {
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 12) {
            Text(text).font(.stBody).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            if let actionTitle, let action { Button(actionTitle, action: action).controlSize(.large) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

/// Primary button: large, neutral (black on light, white on dark), consistent position (Fitts).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration) }

    private struct StyledLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) var isEnabled
        var body: some View {
            configuration.label
                .font(.stBodyStrong)
                .lineLimit(1).minimumScaleFactor(0.85)
                .padding(.horizontal, 16).frame(minHeight: 36)
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .background(RoundedRectangle(cornerRadius: Theme.corner(8)).fill(Theme.textPrimary))
                .opacity(!isEnabled ? 0.3 : configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.stBody)
            .lineLimit(1)
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: Theme.corner(6)).fill(Theme.fillSubtle.opacity(configuration.isPressed ? 2.5 : 1)))
            .contentShape(Rectangle())
    }
}

extension View {
    func contentWidth() -> some View { frame(maxWidth: Theme.maxContentWidth, alignment: .leading).frame(maxWidth: .infinity, alignment: .top) }
}

enum Formatters {
    static func dayTime(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return f.string(from: d)
    }
    static func day(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: d)
    }
    static func longDay(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f.string(from: d)
    }
    static func weekdayShort(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: d)
    }
    static func time(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = .current
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f.string(from: d)
    }
    static func monthYear(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f.string(from: d)
    }
    static func due(_ d: Date?, tz: TimeZone, now: Date = Date()) -> String {
        guard let d else { return "No date" }
        return "\(RelativeTime.describe(d, now: now)) · \(dayTime(d, tz: tz))"
    }
    static func hours(_ h: Double) -> String { h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h) }
    static func percent(_ p: Double) -> String { p == p.rounded() ? "\(Int(p))%" : String(format: "%.1f%%", p) }
}
