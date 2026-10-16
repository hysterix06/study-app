import Foundation

/// Course colours: muted, distinct from each other, readable as white text on a book cover and as an accent on the
/// page, in light and dark. A course keeps its index for good.
public enum CoursePalette {
    public static let colors: [(light: String, dark: String)] = [
        ("#B4532A", "#E48B5C"), // terracotta
        ("#1F7A72", "#4FBFB3"), // teal
        ("#3D5A99", "#8EA6E6"), // indigo
        ("#6B7A2A", "#B3C46A"), // olive
        ("#7A3E6B", "#D08CC0"), // plum
        ("#A8741A", "#E6B45C"), // ochre
        ("#4A6275", "#9DB4C6"), // slate
        ("#A6435A", "#E58FA3"), // rose
    ]

    public static func color(_ index: Int) -> (light: String, dark: String) { colors[((index % colors.count) + colors.count) % colors.count] }
}
