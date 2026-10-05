import Foundation

/// Themes as plain data so contrast can be unit-tested. The app maps these to SwiftUI colors; views only ever use the
/// semantic tokens of `TokenSet`, never a raw color.
public struct RGBA: Hashable, Codable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    public init(hex: String, alpha: Double = 1) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, alpha)
    }

    public static let black = RGBA(0, 0, 0), white = RGBA(1, 1, 1)

    /// This color painted over an opaque background.
    public func over(_ bg: RGBA) -> RGBA {
        RGBA(r * a + bg.r * (1 - a), g * a + bg.g * (1 - a), b * a + bg.b * (1 - a), 1)
    }

    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG 2 contrast ratio between two opaque colors (1…21).
    public static func contrast(_ x: RGBA, _ y: RGBA) -> Double {
        let (l1, l2) = (x.luminance, y.luminance)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// macOS colors a theme can defer to (Paper and Glass keep the system look).
public enum SystemColor: String, Codable {
    case windowBackground, controlBackground, label, accent, green, red
    /// The sidebar keeps the system's translucent material.
    case sidebarMaterial
}

public enum ColorToken: Hashable, Codable {
    case rgba(RGBA)
    /// The system label color at an opacity, which tracks macOS's own text colors.
    case primary(Double)
    /// A system color, with the value it has in this mode for the contrast test.
    case system(SystemColor, approx: RGBA)

    public static func hex(_ h: String, _ alpha: Double = 1) -> ColorToken { .rgba(RGBA(hex: h, alpha: alpha)) }

    /// The color's value in a mode, possibly translucent.
    public func nominal(dark: Bool) -> RGBA {
        switch self {
        case .rgba(let c): return c
        case .primary(let o): return dark ? RGBA(1, 1, 1, 0.85 * o) : RGBA(0, 0, 0, 0.85 * o)
        case .system(_, let approx): return approx
        }
    }
}

/// The semantic tokens, one set per appearance.
public struct TokenSet: Hashable, Codable {
    public var dark: Bool
    public var canvas: ColorToken
    public var surface: ColorToken
    public var surfaceRaised: ColorToken
    public var sidebar: ColorToken
    public var textPrimary: ColorToken
    public var textSecondary: ColorToken
    public var textTertiary: ColorToken
    public var hairline: ColorToken
    public var fillSubtle: ColorToken
    /// The one accent: overdue, due within 48 h, class within the hour, expired sign-in.
    public var attention: ColorToken
    public var success: ColorToken
    public var focusRing: ColorToken
    /// In `CoursePalette` order; courses store the palette name, so switching themes recolors them consistently.
    public var courses: [ColorToken]

    /// Opaque colors for the contrast test.
    public var canvasColor: RGBA { canvas.nominal(dark: dark).over(dark ? .black : .white) }
    public var surfaceColor: RGBA { surface.nominal(dark: dark).over(canvasColor) }
    public func solid(_ t: ColorToken, on bg: RGBA) -> RGBA { t.nominal(dark: dark).over(bg) }

    public func course(_ palette: CoursePalette) -> ColorToken {
        courses[CoursePalette.allCases.firstIndex(of: palette) ?? 0]
    }
}

public enum ThemeFont: String, Codable {
    case system, rounded, monospaced
    /// New York for headings, SF Pro for body.
    case serifHeadings
}

public struct ThemeSpec: Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var character: String
    public var light: TokenSet
    public var dark: TokenSet
    public var font: ThemeFont
    /// High Contrast uses heavier weights.
    public var heavierText: Bool
    public var radiusCard: Double
    public var radiusRow: Double
    /// System translucent materials (Glass, macOS 26+).
    public var glass: Bool
    /// The contrast the theme's body text must reach (4.5 for AA, 7 for High Contrast).
    public var bodyContrast: Double

    public func tokens(dark: Bool) -> TokenSet { dark ? self.dark : light }
}

/// Light, dark, or follow macOS. Chosen separately from the theme.
public enum AppearanceMode: String, CaseIterable, Codable {
    case system, light, dark
    public var label: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum ThemeCatalog {
    public static let all: [ThemeSpec] = [paper, graphite, library, fjord, mono, highContrast]
    public static func theme(_ id: String?) -> ThemeSpec { all.first { $0.id == id } ?? paper }

    private static let lightCourses = ["6B7A8F", "708976", "A9785E", "4F7CA8", "8C6A93", "96814E", "5F7D4E", "B3707A"]

    /// A token set from opaque hex colors; secondary and tertiary text, hairlines and fills are the text color at an opacity.
    private static func tokens(dark: Bool, canvas: String, surface: String, raised: String, sidebar: String, text: String,
                               secondary: Double = 0.70, tertiary: Double = 0.56, hairline: Double = 0.10, fill: Double = 0.045,
                               attention: String, success: String, focus: String) -> TokenSet {
        TokenSet(
            dark: dark, canvas: .hex(canvas), surface: .hex(surface), surfaceRaised: .hex(raised), sidebar: .hex(sidebar),
            textPrimary: .hex(text), textSecondary: .hex(text, secondary), textTertiary: .hex(text, tertiary),
            hairline: .hex(text, hairline), fillSubtle: .hex(text, fill),
            attention: .hex(attention), success: .hex(success), focusRing: .hex(focus),
            courses: (dark ? CoursePalette.allCases.map(\.hex) : lightCourses).map { .hex($0) })
    }

    /// Today's look: system backgrounds and label-based grays, tuned so every text pair passes WCAG AA.
    public static let paper = ThemeSpec(
        id: "paper", name: "Paper", character: "Minimal, high contrast",
        light: TokenSet(
            dark: false,
            canvas: .system(.windowBackground, approx: RGBA(hex: "ECECEC")),
            surface: .primary(0.028),
            surfaceRaised: .system(.controlBackground, approx: RGBA(hex: "FFFFFF")),
            sidebar: .system(.sidebarMaterial, approx: RGBA(hex: "E3E3E3")),
            textPrimary: .primary(1), textSecondary: .primary(0.68), textTertiary: .primary(0.55),
            hairline: .primary(0.08), fillSubtle: .primary(0.035),
            attention: .hex("B8321F"), success: .hex("17753A"),
            focusRing: .system(.accent, approx: RGBA(hex: "0A64D6")),
            courses: ["6B7A8F", "708976", "A9785E", "4F7CA8", "8C6A93", "96814E", "5F7D4E", "B3707A"].map { .hex($0) }),
        dark: TokenSet(
            dark: true,
            canvas: .system(.windowBackground, approx: RGBA(hex: "262626")),
            surface: .primary(0.028),
            surfaceRaised: .system(.controlBackground, approx: RGBA(hex: "1E1E1E")),
            sidebar: .system(.sidebarMaterial, approx: RGBA(hex: "2C2C2C")),
            textPrimary: .primary(1), textSecondary: .primary(0.68), textTertiary: .primary(0.55),
            hairline: .primary(0.08), fillSubtle: .primary(0.035),
            attention: .hex("FF6A55"), success: .system(.green, approx: RGBA(hex: "30D158")),
            focusRing: .system(.accent, approx: RGBA(hex: "3B8CF2")),
            courses: CoursePalette.allCases.map { .hex($0.hex) }),
        font: .system, heavierText: false, radiusCard: 10, radiusRow: 7, glass: false, bodyContrast: 4.5)

    public static let graphite = ThemeSpec(
        id: "graphite", name: "Graphite", character: "Cool grays, calm",
        light: tokens(dark: false, canvas: "F4F5F7", surface: "FFFFFF", raised: "FFFFFF", sidebar: "EBECEF", text: "15171A",
                      attention: "C8323A", success: "1A7543", focus: "3B6FD8"),
        dark: tokens(dark: true, canvas: "16181C", surface: "1E2126", raised: "24272D", sidebar: "1B1D21", text: "E8EAED",
                     attention: "FF6369", success: "3DCB7F", focus: "5B8DEF"),
        font: .system, heavierText: false, radiusCard: 10, radiusRow: 7, glass: false, bodyContrast: 4.5)

    public static let library = ThemeSpec(
        id: "library", name: "Library", character: "Warm paper, bookish",
        light: tokens(dark: false, canvas: "FAF6EE", surface: "FFFDF8", raised: "FFFFFF", sidebar: "F2ECDF", text: "2A2118",
                      secondary: 0.72, tertiary: 0.58, attention: "9B2C2C", success: "2F6B3A", focus: "8A5A2B"),
        dark: tokens(dark: true, canvas: "1B1612", surface: "241E19", raised: "2B241E", sidebar: "17130F", text: "EDE3D3",
                     secondary: 0.72, tertiary: 0.58, attention: "E0716B", success: "86C07F", focus: "D2A06A"),
        font: .serifHeadings, heavierText: false, radiusCard: 8, radiusRow: 6, glass: false, bodyContrast: 4.5)

    public static let fjord = ThemeSpec(
        id: "fjord", name: "Fjord", character: "Cool blue-gray, soft",
        light: tokens(dark: false, canvas: "F2F5F8", surface: "FFFFFF", raised: "FFFFFF", sidebar: "E8EDF2", text: "1B2530",
                      attention: "C2421A", success: "1E7349", focus: "2F7BC0"),
        dark: tokens(dark: true, canvas: "111820", surface: "18212B", raised: "1E2833", sidebar: "0E141B", text: "DCE4EC",
                     attention: "FF7A52", success: "4CCB86", focus: "6AA8E0"),
        font: .rounded, heavierText: false, radiusCard: 14, radiusRow: 10, glass: false, bodyContrast: 4.5)

    public static let mono = ThemeSpec(
        id: "mono", name: "Mono", character: "Terminal-like, dense",
        light: tokens(dark: false, canvas: "FFFFFF", surface: "F5F5F5", raised: "FFFFFF", sidebar: "F0F0F0", text: "000000",
                      attention: "A85A00", success: "1D6B2F", focus: "000000"),
        dark: tokens(dark: true, canvas: "000000", surface: "111111", raised: "161616", sidebar: "0A0A0A", text: "FFFFFF",
                     attention: "FFB020", success: "3DDC84", focus: "FFFFFF"),
        font: .monospaced, heavierText: false, radiusCard: 2, radiusRow: 2, glass: false, bodyContrast: 4.5)

    public static let highContrast = ThemeSpec(
        id: "high-contrast", name: "High Contrast", character: "Accessibility first",
        light: tokens(dark: false, canvas: "FFFFFF", surface: "FAFAFA", raised: "FFFFFF", sidebar: "F2F2F2", text: "000000",
                      secondary: 0.82, tertiary: 0.66, hairline: 0.35, fill: 0.07, attention: "9A001C", success: "07571F", focus: "0040C0"),
        dark: tokens(dark: true, canvas: "000000", surface: "0D0D0D", raised: "141414", sidebar: "0A0A0A", text: "FFFFFF",
                     secondary: 0.82, tertiary: 0.66, hairline: 0.35, fill: 0.10, attention: "FF8080", success: "4AE08A", focus: "7FB2FF"),
        font: .system, heavierText: true, radiusCard: 10, radiusRow: 7, glass: false, bodyContrast: 7)
}
