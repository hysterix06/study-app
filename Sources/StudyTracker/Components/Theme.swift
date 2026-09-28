import SwiftUI
import StudyCore

/// §7.1: system font on a 5-step scale, near-black/near-white text, one accent for "needs attention now",
/// muted course colors used only as dots and thin bars.
enum Theme {
    static let accent = Color(red: 0.86, green: 0.26, blue: 0.16)     // urgency only
    static let hairline = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.035)
    static let cardFill = Color.primary.opacity(0.028)
    static let secondaryText = Color.primary.opacity(0.62)
    static let tertiaryText = Color.primary.opacity(0.42)
    static let maxContentWidth: CGFloat = 960
    static let radius: CGFloat = 10

    enum Size { static let xs: CGFloat = 12, s: CGFloat = 14, m: CGFloat = 16, l: CGFloat = 20, xl: CGFloat = 28 }

    static func courseColor(_ token: String?) -> Color {
        let hex = CoursePalette(rawValue: token ?? "")?.hex ?? CoursePalette.slate.hex
        return Color(hex: hex)
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension Font {
    static let stTitle = Font.system(size: Theme.Size.xl, weight: .semibold)
    static let stHeading = Font.system(size: Theme.Size.l, weight: .semibold)
    static let stBodyStrong = Font.system(size: Theme.Size.m, weight: .medium)
    static let stBody = Font.system(size: Theme.Size.s)
    static let stSmall = Font.system(size: Theme.Size.xs)
    static let stSmallStrong = Font.system(size: Theme.Size.xs, weight: .semibold)
}

struct CourseDot: View {
    var color: String?
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(Theme.courseColor(color)).frame(width: size, height: size).accessibilityHidden(true)
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
        .foregroundStyle(urgent ? Theme.accent : Theme.secondaryText)
        .background(RoundedRectangle(cornerRadius: 4).fill(urgent ? Theme.accent.opacity(0.1) : Theme.subtleFill))
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.stSmallStrong).foregroundStyle(Theme.tertiaryText).kerning(0.6)
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
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.hairline))
    }
}

/// One sentence and one action (§7.1 empty states).
struct EmptyState: View {
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 12) {
            Text(text).font(.stBody).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            if let actionTitle, let action { Button(actionTitle, action: action).controlSize(.large) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

/// Primary button: large, neutral (black on light, white on dark), consistent position (Fitts).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.stBodyStrong)
            .lineLimit(1).minimumScaleFactor(0.85)
            .padding(.horizontal, 16).frame(minHeight: 36)
            .foregroundStyle(Color(nsColor: .textBackgroundColor))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.stBody)
            .lineLimit(1)
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill.opacity(configuration.isPressed ? 2.5 : 1)))
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
