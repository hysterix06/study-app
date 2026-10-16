import AppKit
import SwiftUI
import StudyCore

extension Color {
    /// "#B4532A"
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// A course's colour, lighter in dark mode.
    static func course(_ index: Int) -> Color {
        let c = CoursePalette.color(index)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: dark ? c.dark : c.light))
        })
    }

    /// The cover keeps the deeper colour in both modes, so white text stays readable.
    static func cover(_ index: Int) -> Color { Color(hex: CoursePalette.color(index).light) }
}

extension Font {
    static let label = Font.system(size: 11, weight: .semibold)
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
}

/// Small-caps style section label.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.label).tracking(1.4).foregroundStyle(.secondary)
    }
}

enum Format {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// "Today", "Tomorrow", "Thursday", or "Thu 23 Oct" further out.
    static func day(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day, (2...6).contains(days) {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
