import XCTest
@testable import StudyCore

final class BookTests: XCTestCase {
    func testParsesEveryConventionInTheSampleChapter() throws {
        let doc = ChapterDoc.parse(fixtureText("chapter-sample.md"))
        XCTAssertEqual(doc.title, "Pricing a room that expires tonight")
        XCTAssertTrue(doc.standfirst?.hasPrefix("A hotel room is the most perishable") == true)
        XCTAssertNil(doc.sections[0].title, "the opening paragraphs come before the first ##")
        XCTAssertEqual(doc.sections.compactMap(\.title), ["Occupancy alone tells half the story", "Average daily rate is the other half",
                                                         "RevPAR brings them together", "Why demand curves matter here",
                                                         "A simple picture of the room inventory", "Check yourself"])
        let blocks = doc.sections.flatMap(\.blocks)
        XCTAssertTrue(blocks.contains { if case .box("course", nil, let m) = $0 { return m.contains("volume trap") }; return false })
        XCTAssertTrue(doc.sections[1].blocks.contains { if case .box("slide", nil, let m) = $0 { return m.hasPrefix("- Occupancy") }; return false })
        XCTAssertTrue(blocks.contains { if case .box("example", "Two Tuesdays at the same hotel", _) = $0 { return true }; return false })

        // The flow inside the example box is drawn right after it.
        let revpar = doc.sections[3].blocks
        guard let boxAt = revpar.firstIndex(where: { if case .box("example", _, _) = $0 { return true }; return false }) else { return XCTFail("no example box") }
        guard case .figure(_, let flowCaption) = revpar[boxAt + 1] else { return XCTFail("the box's diagram should follow it") }
        XCTAssertEqual(flowCaption, "How a revenue manager reads a night")

        let figures = blocks.compactMap { b -> (String, String?)? in if case let .figure(svg, c) = b { return (svg, c) }; return nil }
        XCTAssertEqual(figures.count, 3)
        XCTAssertEqual(figures.map(\.1), ["How a revenue manager reads a night", "A demand shift on a festival weekend", "Tonight's 200 rooms"])
        XCTAssertFalse(figures[1].0.contains("festival weekend</text>"), "the title is a caption, not drawn inside")

        guard case .check(let qa)? = doc.sections.last?.blocks.first else { return XCTFail("no check") }
        XCTAssertEqual(qa.count, 3)
        XCTAssertEqual(qa[1].a, "It can't be stored: a room unsold tonight is revenue lost for good.")
        XCTAssertEqual(doc.cards.map(\.q), ["Occupancy", "ADR (average daily rate)", "RevPAR", "Perishability"])
        XCTAssertTrue(doc.warnings.isEmpty, "\(doc.warnings)")
        XCTAssertGreaterThan(doc.words, 500)
        XCTAssertEqual(doc.problems, ["it has \(doc.words) words, fewer than 1200"], "the sample is short on purpose")
    }

    func testToleratesWhatModelsGetWrong() {
        let raw = """
        ```markdown
        # Chapter 3: A title
        *The standfirst.*

        Opening.

        ## One
        Text with a ```diagram that isn't one.
        ```diagram
        {"kind": "nonsense"}
        ```

        ## Two
        :::sidebar Odd kind
        Kept as a note.
        :::
        :::

        ## Check yourself
        **Q1:** First question?
        **A1:** First answer,
        over two lines.
        Q2. Second question?
        A2. Second answer.
        ```
        """
        let doc = ChapterDoc.parse(raw)
        XCTAssertEqual(doc.title, "A title")
        XCTAssertEqual(doc.standfirst, "The standfirst.")
        XCTAssertEqual(doc.warnings, ["A diagram couldn't be read and was left out."])
        let wrapped = ChapterDoc.parse("# T\n\n## S\n```diagram\n{\"kind\":\"svg\",\"title\":\"Floors\",\"svg\":\"<svg viewBox=\\\"0 0 10 10\\\"><line x1=\\\"0\\\" y1=\\\"0\\\" x2=\\\"9\\\" y2=\\\"9\\\"/></svg>\"}\n```")
        guard case .figure(_, "Floors")? = wrapped.sections.first?.blocks.first else { return XCTFail("an svg sent as a diagram is still drawn: \(wrapped)") }
        XCTAssertEqual(doc.sections[2].blocks, [.box(kind: "note", title: "Odd kind", markdown: "Kept as a note.")])
        XCTAssertEqual(doc.sections[3].blocks, [.check([.init(q: "First question?", a: "First answer,\nover two lines."),
                                                       .init(q: "Second question?", a: "Second answer.")])])
    }

    func testThemedDiagramsTakeTheirColoursFromThePage() throws {
        let graph = try XCTUnwrap(Diagram.parse(JSON.parse(#"{"kind":"graph","curves":[{"label":"S","points":[[1,1],[9,9]]}],"areas":[{"label":"CS","points":[[0,9],[5,5],[0,5]]}],"points":[{"label":"E","x":5,"y":5}]}"#)).diagram)
        let themed = DiagramSVG.render(graph, themed: true)
        XCTAssertNil(themed.range(of: #"#[0-9a-fA-F]{3,6}\b"#, options: .regularExpression), themed)
        XCTAssertTrue(themed.contains("var(--fig-s0)") && themed.contains("var(--fig-a0)") && themed.contains("var(--fig-paper)"))
        XCTAssertFalse(themed.contains("width=\"480"), "the page sizes it")
        XCTAssertTrue(DiagramSVG.render(graph).contains("stroke=\"\(DiagramSVG.series[0])\""), "exports keep fixed colours")
    }

    func testBookPlanKeepsOnlyWhatIsUsable() {
        let json: [String: Any] = [
            "is_course": true, "book_title": "Hospitality Marketing", "language": "en",
            "chapters": [
                ["title": "What marketing is", "summary": "s", "syllabus_ref": "CH1", "week": 1, "files": [1, 99]],
                ["title": "what marketing is", "summary": "repeat", "files": []],
                ["title": "Services", "summary": "s", "week": 77, "files": [2]],
                ["title": "  ", "summary": "no title"],
                ["title": "Research", "summary": "s", "files": [3, 3]],
            ],
        ]
        let (plan, warnings) = BookPlan.parse(json, knownFiles: [1, 2, 3])
        XCTAssertEqual(plan?.chapters.map(\.title), ["What marketing is", "Services", "Research"])
        XCTAssertEqual(plan?.chapters[0].files, [1])
        XCTAssertNil(plan?.chapters[1].week)
        XCTAssertEqual(plan?.chapters[2].files, [3])
        XCTAssertTrue(warnings.contains { $0.contains("repeated") })
        XCTAssertNil(BookPlan.parse(["is_course": true, "chapters": [["title": "Only one"]]], knownFiles: []).plan)
        XCTAssertEqual(BookPlan.parse(["is_course": false, "book_title": "Library"], knownFiles: []).plan?.isCourse, false)
    }

    func testPromptsStayWithinTheirBudgets() {
        let files = (1...40).map { BookPrompts.File(id: $0, title: "Lecture \($0)", section: "Week \($0 / 4)",
                                                    headings: ["Heading A", "Heading B", "Heading C", "Heading D"],
                                                    text: String(repeating: "Slide text line.\n", count: 400)) }
        let toc = BookPrompts.tocUser(course: .init(name: "Marketing", code: "MKT"), syllabus: String(repeating: "x", count: 50_000), files: files)
        XCTAssertLessThan(toc.count, BookPrompts.tocSyllabusCap + BookPrompts.tocFilesCap + 600)
        XCTAssertTrue(toc.contains("[1] Lecture 1 · Heading A; Heading B; Heading C"))

        let plan = BookPlan(isCourse: true, title: "Marketing", language: "en",
                            chapters: [.init(title: "One", summary: "First", syllabusRef: "CH1", files: [1, 2, 3])])
        let block = BookPrompts.chapterBlock(number: 1, chapter: plan.chapters[0], files: Array(files.prefix(3)))
        XCTAssertLessThan(block.count, BookPrompts.chapterOutlineCap + BookPrompts.chapterExcerptCap + 600)
        XCTAssertEqual(block.components(separatedBy: "### Lecture").count - 1, 3, "every file gets a share of the excerpt")
        XCTAssertTrue(BookPrompts.chapterCourseBlock(course: .init(name: "Marketing"), plan: plan, syllabus: "Week 1: intro").contains("1. One: First"))
        XCTAssertFalse(BookPrompts.chapterSystem.contains("\\(course") || BookPrompts.chapterSystem.contains("{{"), "the system prompt is fixed")
        XCTAssertTrue(BookPrompts.chapterSystem.contains(#"\( … \)"#))
    }
}
