import XCTest
import CoreGraphics
@testable import StudyCore

final class PlannerTests: XCTestCase {
    let now = at("2026-09-28", "08:00")

    func testPlacesBlocksBackwardAvoidingClassesAndBusy() {
        let report = Assignment(id: 1, courseId: 1, title: "Pricing report", kind: .report, dueAt: at("2026-10-02", "23:59"),
                                weightPct: 30, estHours: 3)
        // A class Thursday 09:00–10:30 and a work shift Thursday 18:00–23:00.
        let busy = [(start: at("2026-10-01", "09:00"), end: at("2026-10-01", "10:30")),
                    (start: at("2026-10-01", "18:00"), end: at("2026-10-01", "23:00"))]
        let r = StudyPlanner.plan(assignments: [report], busy: busy, existing: [], settings: PlannerSettings(), now: now, tz: madrid)
        XCTAssertEqual(r.blocks.reduce(0) { $0 + $1.plannedMinutes }, 180)
        XCTAssertTrue(r.warnings.isEmpty)
        for b in r.blocks {
            XCTAssertTrue((45...90).contains(b.plannedMinutes))
            XCTAssertLessThanOrEqual(b.end, report.dueAt!.adding(hours: -12))
            for x in busy { XCTAssertFalse(b.plannedStart < x.end && b.end > x.start, "block overlaps busy time") }
            let start = LocalTime(b.plannedStart, tz: madrid)
            XCTAssertGreaterThanOrEqual(start, t("08:00"))
            XCTAssertLessThanOrEqual(LocalTime(b.end, tz: madrid), t("22:00"))
        }
        // At most one block per assignment per day outside the final 48 hours.
        let days = r.blocks.map { LocalDate($0.plannedStart, tz: madrid) }
        let early = days.filter { $0 < d("2026-10-01") }
        XCTAssertEqual(early.count, Set(early).count)
    }

    func testDeterministic() {
        let a = Assignment(id: 1, courseId: 1, title: "Exam", kind: .exam, dueAt: at("2026-10-09", "09:00"), weightPct: 50)
        let r1 = StudyPlanner.plan(assignments: [a], busy: [], existing: [], settings: PlannerSettings(), now: now, tz: madrid)
        let r2 = StudyPlanner.plan(assignments: [a], busy: [], existing: [], settings: PlannerSettings(), now: now, tz: madrid)
        XCTAssertEqual(r1.blocks.map(\.plannedStart), r2.blocks.map(\.plannedStart))
        XCTAssertEqual(r1.blocks.reduce(0) { $0 + $1.plannedMinutes }, 360, "exam default is 6 hours")
    }

    func testWarnsWhenTimeRunsOut() {
        let a = Assignment(id: 1, courseId: 1, title: "Huge project", kind: .project, dueAt: at("2026-09-29", "23:59"), estHours: 20)
        let r = StudyPlanner.plan(assignments: [a], busy: [], existing: [], settings: PlannerSettings(), now: now, tz: madrid)
        XCTAssertFalse(r.warnings.isEmpty)
        XCTAssertTrue(r.warnings[0].contains("Not enough free time"))
    }

    func testDailyCapRespected() {
        let items = (1...4).map { Assignment(id: $0, courseId: 1, title: "Task \($0)", dueAt: at("2026-10-03", "23:59"), estHours: 3) }
        let r = StudyPlanner.plan(assignments: items, busy: [], existing: [], settings: PlannerSettings(), now: now, tz: madrid)
        let byDay = Dictionary(grouping: r.blocks, by: { LocalDate($0.plannedStart, tz: madrid) }).mapValues { $0.reduce(0) { $0 + $1.plannedMinutes } }
        XCTAssertTrue(byDay.values.allSatisfy { $0 <= 180 })
    }

    func testSplit() {
        XCTAssertEqual(StudyPlanner.split(minutes: 180), [60, 60, 60])
        XCTAssertEqual(StudyPlanner.split(minutes: 100), [55, 45])
        XCTAssertEqual(StudyPlanner.split(minutes: 30), [45])
        XCTAssertTrue(StudyPlanner.split(minutes: 250).allSatisfy { (45...90).contains($0) })
    }
}

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

    func testImageHeavyDeckAndImageTextEnrichment() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Chart", bullets: [], notes: nil, picture: "Yield management curve", table: nil, chart: false),
            (title: "Photo", bullets: [], notes: nil, picture: "Front desk check-in flow", table: nil, chart: false),
        ])
        guard case .imported(let id, _) = store.importMaterial(from: deck, courseId: ids.hm) else { return XCTFail() }
        XCTAssertEqual(store.chunks(materialId: id).filter { !$0.images.isEmpty }.count, 2)
        XCTAssertEqual(store.materialsNeedingImageText(), [id])
        XCTAssertEqual(store.enrichImageText(materialId: id), 2)
        let extra = store.chunks(materialId: id)[0].extraMd ?? ""
        XCTAssertTrue(extra.contains("Text in pictures"))
        XCTAssertTrue(extra.lowercased().contains("yield"), "on-device OCR read the picture: \(extra)")
        XCTAssertEqual(store.enrichImageText(materialId: id), 0, "idempotent")
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
        let store = try makeStore()
        try seedCourses(store)
        let bad = FixtureFactory.tempDir().appendingPathComponent("broken.pptx")
        try Data("not a zip at all".utf8).write(to: bad)
        guard case .failed(let msg) = store.importMaterial(from: bad) else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("broken.pptx"))
        XCTAssertEqual(store.materials(statuses: ["failed"]).count, 1)
        XCTAssertNotNil(store.materials(statuses: ["failed"]).first?.statusDetail)
    }

    func testImportDedupesSuggestsCourseAndFiles() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let deck = try slides()
        guard case .imported(let id, _) = store.importMaterial(from: deck) else { return XCTFail() }
        let m = store.material(id)!
        XCTAssertEqual(m.suggestedCourseId, ids.hm, "HM210 in the filename")
        XCTAssertEqual(m.status, "inbox")
        XCTAssertTrue(m.storedPath!.contains("_unfiled"))
        guard case .duplicate(let existing, _) = store.importMaterial(from: deck) else { return XCTFail("expected duplicate") }
        XCTAssertEqual(existing, id)
        try store.confirmMaterial(id, courseId: ids.hm)
        let filed = store.material(id)!
        XCTAssertEqual(filed.status, "ready")
        XCTAssertTrue(filed.storedPath!.contains("/HM210/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.absolute(filed.storedPath!).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.absolute(filed.assetsPath!).path))
    }

    func testSkipLeavesInboxButKeepsLectureFiled() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        guard case .imported(let id, _) = store.importMaterial(from: try slides(), courseId: ids.hm) else { return XCTFail() }
        XCTAssertEqual(store.unprocessedMaterials().map(\.id), [id])
        XCTAssertEqual(store.inboxCount(), 1)
        store.skipMaterial(id)
        XCTAssertTrue(store.unprocessedMaterials().isEmpty)
        XCTAssertEqual(store.inboxCount(), 0)
        XCTAssertEqual(store.material(id)?.courseId, ids.hm, "skipping keeps the lecture in its course")
        XCTAssertNil(store.material(id)?.processedAt, "skipping is not processing, so Insights stay honest")
        try store.deleteMaterial(id)
        XCTAssertTrue(store.skippedMaterialIds().isEmpty, "SQLite can reuse the id; the next import must not inherit the skip")
    }

    func testRoleGuessing() {
        XCTAssertEqual(StudyStore.guessRole(filename: "HM210 Course Outline.pdf", title: "", text: ""), .syllabus)
        XCTAssertEqual(StudyStore.guessRole(filename: "Marking rubric report.docx", title: "", text: ""), .rubric)
        XCTAssertEqual(StudyStore.guessRole(filename: "Past paper 2024.pdf", title: "", text: ""), .pastExam)
        XCTAssertEqual(StudyStore.guessRole(filename: "Assignment brief.pdf", title: "", text: ""), .brief)
        XCTAssertEqual(StudyStore.guessRole(filename: "Week 3 slides.pptx", title: "", text: ""), .lecture)
    }

    func testCornellSheetPDF() throws {
        let cues = (1...12).map { CornellSheet.Cue(text: "Why does cue \($0) matter for pricing decisions in a full-service hotel?", kind: "question", sourceLocators: ["slide \($0)"]) }
        let sheet = CornellSheet(title: "Overbooking", courseCode: "HM210", materialTitle: "Week 3", date: "2026-09-28", cues: cues,
                                 summaryPrompt: "In two sentences, when is overbooking worth the risk?", lookYourself: ["slide 2"])
        let data = CornellRenderer.pdf(sheet, paper: .a4)
        let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        XCTAssertGreaterThanOrEqual(doc.numberOfPages, 2, "12 cues × 5 ruled lines need more than one A4 page")
        XCTAssertEqual(doc.page(at: 1)!.getBoxRect(.mediaBox).width, 595.28, accuracy: 0.1)
        XCTAssertTrue(sheet.obsidianMarkdown.hasPrefix("---\ncourse: \"HM210\""))
    }

    func testCueGuardRejectsAnswers() {
        XCTAssertTrue(StudyStore.cueLooksLikeAnswer(.init(text: "RevPAR: revenue per available room, ADR times occupancy", kind: "term", sourceChunkIds: [1])))
        XCTAssertFalse(StudyStore.cueLooksLikeAnswer(.init(text: "RevPAR", kind: "term", sourceChunkIds: [1])))
        XCTAssertFalse(StudyStore.cueLooksLikeAnswer(.init(text: "How is RevPAR calculated?", kind: "question", sourceChunkIds: [1])))
    }
}
