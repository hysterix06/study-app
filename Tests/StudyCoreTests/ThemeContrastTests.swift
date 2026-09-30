import XCTest
@testable import StudyCore

/// WCAG 2.1 AA for every theme and appearance: body text 4.5:1 (High Contrast 7:1), tertiary text, the accent as
/// large or bold text, and course dots 3:1. Colors that come from system materials are checked at their typical value.
final class ThemeContrastTests: XCTestCase {
    func check(_ theme: ThemeSpec, _ set: TokenSet, file: StaticString = #filePath, line: UInt = #line) {
        let mode = set.dark ? "dark" : "light"
        for (bgName, bg) in [("canvas", set.canvasColor), ("surface", set.surfaceColor)] {
            func ratio(_ t: ColorToken) -> Double { RGBA.contrast(set.solid(t, on: bg), bg) }
            let pairs: [(String, ColorToken, Double)] = [
                ("textPrimary", set.textPrimary, max(theme.bodyContrast, 7)),
                ("textSecondary", set.textSecondary, theme.bodyContrast),
                ("attention", set.attention, theme.bodyContrast),
                ("success", set.success, theme.bodyContrast),
                ("textTertiary", set.textTertiary, 3),
            ]
            for (name, token, minimum) in pairs {
                let r = ratio(token)
                XCTAssertGreaterThanOrEqual(r, minimum, "\(theme.name) \(mode): \(name) on \(bgName) is \(String(format: "%.2f", r)):1",
                                            file: file, line: line)
            }
            for (i, c) in set.courses.enumerated() {
                let r = ratio(c)
                XCTAssertGreaterThanOrEqual(r, 3, "\(theme.name) \(mode): course \(CoursePalette.allCases[i]) on \(bgName) is \(String(format: "%.2f", r)):1",
                                            file: file, line: line)
            }
        }
    }

    func testEveryThemeAndMode() {
        for theme in ThemeCatalog.all {
            check(theme, theme.light)
            check(theme, theme.dark)
            XCTAssertEqual(theme.light.courses.count, CoursePalette.allCases.count, theme.name)
            XCTAssertEqual(theme.dark.courses.count, CoursePalette.allCases.count, theme.name)
            XCTAssertFalse(theme.light.dark)
            XCTAssertTrue(theme.dark.dark)
        }
    }

    func testThemeIdsAreUniqueAndPaperIsDefault() {
        XCTAssertEqual(Set(ThemeCatalog.all.map(\.id)).count, ThemeCatalog.all.count)
        XCTAssertEqual(ThemeCatalog.theme(nil).id, "paper")
        XCTAssertEqual(ThemeCatalog.theme("nope").id, "paper")
    }

    func testContrastMath() {
        XCTAssertEqual(RGBA.contrast(.black, .white), 21, accuracy: 0.01)
        XCTAssertEqual(RGBA.contrast(.white, .white), 1, accuracy: 0.001)
        XCTAssertEqual(RGBA(0, 0, 0, 0.5).over(.white).r, 0.5, accuracy: 0.001)
    }
}
