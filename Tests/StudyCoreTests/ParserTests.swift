import XCTest
import CoreGraphics
@testable import StudyCore

final class ParserTests: XCTestCase {
    func slides() throws -> URL {
        try FixtureFactory.pptx(slides: [
            (title: "Overbooking", bullets: [(0, "Why hotels overbook"), (1, "No-shows and late cancellations")], notes: "Mention the airline analogy.",
             picture: nil, table: nil, chart: false),
            (title: "Occupancy", bullets: [(0, "Seasonality")], notes: nil, picture: "RevPAR = ADR x Occupancy",
             table: [["Metric", "Value"], ["ADR", "120"]], chart: true),
            (title: "Summary", bullets: [], notes: nil, picture: nil, table: nil, chart: false),
        ], title: "PowerPoint Presentation")
    }

    func testPPTXSlidesNotesTablesChartsAndPictures() throws {
        let dir = FixtureFactory.tempDir()
        let p = try MaterialParser.parse(try slides(), options: .init(assetsDir: dir))
        XCTAssertEqual(p.kind, "slides")
        XCTAssertEqual(p.title, "Overbooking", "generic metadata titles fall back to the first slide title")
        XCTAssertEqual(p.chunks.count, 3)
        XCTAssertEqual(p.chunks[0].locator, "slide 1")
        XCTAssertTrue(p.chunks[0].textMd.contains("- Why hotels overbook"))
        XCTAssertTrue(p.chunks[0].textMd.contains("  - No-shows"), "bullet levels are kept")
        XCTAssertFalse(p.chunks[0].textMd.contains("\n1"), "slide numbers are dropped")
        XCTAssertEqual(p.chunks[0].notesMd, "Mention the airline analogy.")
        XCTAssertEqual(p.chunks[1].imageCount, 2, "picture + chart")
        XCTAssertEqual(p.chunks[1].images.count, 1)
        XCTAssertTrue(p.chunks[1].extraMd!.contains("| ADR | 120 |"))
        XCTAssertTrue(p.chunks[1].extraMd!.contains("Occupancy by month"))
        XCTAssertTrue(p.chunks[1].extraMd!.contains("| Jan | 0.62 |"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(p.chunks[1].images[0]).path))
    }

    func testImageHeavyDeckKeepsItsPictures() throws {
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Chart", bullets: [], notes: nil, picture: "Yield management curve", table: nil, chart: false),
            (title: "Photo", bullets: [], notes: nil, picture: "Front desk check-in flow", table: nil, chart: false),
        ])
        let p = try MaterialParser.parse(deck, options: .init(assetsDir: FixtureFactory.tempDir()))
        XCTAssertEqual(p.chunks.filter { !$0.images.isEmpty }.count, 2)
    }

    func testDOCXSections() throws {
        let url = try FixtureFactory.docx(sections: [
            (heading: nil, paragraphs: ["Preface paragraph."]),
            (heading: "Forecasting", paragraphs: ["Demand forecasting uses history.", "Pickup models."]),
            (heading: "Pricing", paragraphs: ["Dynamic pricing."]),
        ])
        let p = try MaterialParser.parse(url)
        XCTAssertEqual(p.kind, "doc")
        XCTAssertEqual(p.chunks.map(\.locator), ["section \"Introduction\"", "section \"Forecasting\"", "section \"Pricing\""])
        XCTAssertTrue(p.chunks[2].textMd.contains("| RevPAR | ADR x Occupancy |"))
    }

    func testTextPDF() throws {
        let url = FixtureFactory.textPDF(pages: ["Page one about forecasting demand in hotels.", "Page two about overbooking policy."])
        let p = try MaterialParser.parse(url, options: .init(assetsDir: FixtureFactory.tempDir()))
        XCTAssertEqual(p.kind, "pdf")
        XCTAssertEqual(p.chunks.map(\.locator), ["p. 1", "p. 2"])
        XCTAssertTrue(p.chunks[1].textMd.contains("overbooking"))
        XCTAssertEqual(p.status, "ready")
    }

    func testScannedPDFIsRecognizedOnDevice() throws {
        let url = FixtureFactory.scannedPDF(text: "Break even point equals fixed costs divided by contribution margin")
        let p = try MaterialParser.parse(url, options: .init(assetsDir: FixtureFactory.tempDir()))
        XCTAssertTrue(p.chunks[0].ocr)
        XCTAssertTrue(p.chunks[0].textMd.lowercased().contains("fixed costs"), p.chunks[0].textMd)
        XCTAssertEqual(p.status, "ready")
        XCTAssertEqual(p.chunks[0].images.count, 1, "the page image is kept so Claude can look at it")
    }

    func testScannedPDFWithoutOCRNeedsOCR() throws {
        let url = FixtureFactory.scannedPDF(text: "Contribution margin")
        let p = try MaterialParser.parse(url, options: .init(assetsDir: nil, ocrScannedPages: false))
        XCTAssertEqual(p.status, "needs_ocr")
    }

    func testMarkdownSplitsOnHeadings() throws {
        let p = try MaterialParser.parse(fixtureURL("syllabus.md"))
        XCTAssertEqual(p.title, "HM210 Revenue Management — Course Outline")
        XCTAssertTrue(p.chunks.map(\.locator).contains("section \"Assessment\""))
    }

    func testCorruptFileFailsWithoutCrashing() throws {
        let bad = FixtureFactory.tempDir().appendingPathComponent("broken.pptx")
        try Data("not a zip at all".utf8).write(to: bad)
        XCTAssertThrowsError(try MaterialParser.parse(bad))
    }
}
