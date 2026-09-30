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

public enum ThemeCatalog {
    public static let all: [ThemeSpec] = [paper]
    public static func theme(_ id: String?) -> ThemeSpec { all.first { $0.id == id } ?? paper }

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
}
