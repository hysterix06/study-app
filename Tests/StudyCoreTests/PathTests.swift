import XCTest
@testable import StudyCore

final class PathTests: XCTestCase {
    var store: StudyStore!
    var ids: (term: Int, hm: Int, mkt: Int)!
    var lecture: Int!

    override func setUpWithError() throws {
        store = try makeStore()
        ids = try seedCourses(store)
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Overbooking", bullets: [(0, "Selling more rooms than exist")], notes: nil, picture: nil, table: nil, chart: false),
            (title: "No-show rate", bullets: [(0, "Share of bookings that don't arrive")], notes: nil, picture: nil, table: nil, chart: false),
        ])
        guard case .imported(let m, _) = store.importMaterial(from: deck, courseId: ids.hm) else { return XCTFail() }
        lecture = m
    }

    func path(_ titles: [[String]], ids topicIds: [String: Int] = [:]) -> PathInput {
        PathInput(units: titles.enumerated().map { i, ts in
            PathInput.Unit(title: "Unit \(i + 1)", topics: ts.map { PathInput.Topic(id: topicIds[$0], title: $0) })
        })
    }

    // MARK: Merging

    func testARebuiltPathKeepsTopicsAndProgress() throws {
        let first = try store.savePath(courseId: ids.hm, path([["Demand", "Pricing"], ["Overbooking"]]), tier: "basic", builtWith: "free AI")
        XCTAssertEqual(first.created, 3)
        let overbooking = try XCTUnwrap(first.topicIds["overbooking"])
        try store.setNotebookWritten(overbooking, written: true, page: "14")
        XCTAssertEqual(store.topic(overbooking)?.mastery, .familiar)

        // The course builder reorders, renames one topic by id, and drops "Pricing" (never started).
        let renamed = try store.savePath(courseId: ids.hm, PathInput(units: [
            PathInput.Unit(title: "Capacity", topics: [PathInput.Topic(id: overbooking, title: "Overbooking and walking guests"), PathInput.Topic(title: "Demand")]),
        ]), tier: "full", builtWith: "Claude Code")
        XCTAssertEqual(renamed.created, 0)
        XCTAssertEqual(renamed.updated, 2)
        XCTAssertEqual(renamed.retired, 1)
        let t = try XCTUnwrap(store.topic(overbooking))
        XCTAssertEqual(t.title, "Overbooking and walking guests")
        XCTAssertEqual(t.notebookPage, "14", "the student's notebook page stays")
        XCTAssertEqual(t.mastery, .familiar)
        XCTAssertEqual(store.topics(courseId: ids.hm).map(\.title), ["Overbooking and walking guests", "Demand"])
        XCTAssertEqual(store.path(courseId: ids.hm)?.tier, "full")
        XCTAssertEqual(store.path(courseId: ids.hm)?.version, 2)
        XCTAssertEqual(store.topicNumbers(courseId: ids.hm)[overbooking], "1.1")
    }

    func testAStartedTopicIsKeptWhenThePathDropsIt() throws {
        let r = try store.savePath(courseId: ids.hm, path([["Demand", "Yield management"]]), tier: "basic", builtWith: nil)
        let yield = try XCTUnwrap(r.topicIds["yield-management"])
        try store.setNotebookWritten(yield, written: true)
        let again = try store.savePath(courseId: ids.hm, path([["Demand", "Forecasting"]]), tier: "full", builtWith: nil)
        XCTAssertEqual(again.kept, 1)
        XCTAssertEqual(store.units(courseId: ids.hm).last?.title, "Also studied")
        XCTAssertFalse(store.topic(yield)!.retired, "nothing the student did disappears")
    }

    func testPrerequisiteLoopsAreDroppedAndForeignSourcesRefused() throws {
        var input = PathInput(units: [PathInput.Unit(title: "U", topics: [
            PathInput.Topic(title: "A", prereqs: ["C"], sources: [PathInput.Source(materialId: lecture), PathInput.Source(materialId: 99_999)]),
            PathInput.Topic(title: "B", prereqs: ["A"]),
            PathInput.Topic(title: "C", prereqs: ["B"]),
        ])])
        input.assessments = [PathInput.Assessment(assignmentId: 12345, topics: ["A"])]
        let r = try store.savePath(courseId: ids.hm, input, tier: "full", builtWith: nil)
        XCTAssertTrue(r.warnings.contains { $0.contains("loop") })
        XCTAssertTrue(r.warnings.contains { $0.contains("99999") })
        XCTAssertTrue(r.warnings.contains { $0.contains("12345") })
        let a = try XCTUnwrap(r.topicIds["a"]), b = try XCTUnwrap(r.topicIds["b"]), c = try XCTUnwrap(r.topicIds["c"])
        XCTAssertEqual(store.topic(a)?.prereqIds, [c])
        XCTAssertEqual(store.topic(b)?.prereqIds, [a])
        XCTAssertEqual(store.topic(c)?.prereqIds, [], "C → B would close the loop A → C → B → A")
        XCTAssertEqual(store.coverage(topicId: a).map(\.materialId), [lecture])
    }

    func testASimplerPathNeverReplacesAFullerOne() throws {
        try store.savePath(courseId: ids.hm, path([["Demand"]]), tier: "full", builtWith: "Claude Code")
        XCTAssertThrowsError(try store.savePath(courseId: ids.hm, path([["Demand"]]), tier: "basic", builtWith: "free AI"))
        XCTAssertThrowsError(try store.savePath(courseId: ids.hm, PathInput(units: []), tier: "full", builtWith: nil))
        XCTAssertNil(try store.buildSkeletonPath(courseId: ids.hm), "a course with a path keeps it")
    }

    func testAssessmentsKnowTheirTopics() throws {
        let exam = try store.saveAssignment(Assignment(courseId: ids.hm, title: "Final exam", kind: .exam, dueAt: Date().addingTimeInterval(9 * 86_400), weightPct: 60))
        var input = path([["Demand", "Pricing"]])
        input.assessments = [PathInput.Assessment(assignmentId: exam, topics: ["Pricing"])]
        let r = try store.savePath(courseId: ids.hm, input, tier: "full", builtWith: nil)
        XCTAssertEqual(store.assessmentTopicIds(assignmentId: exam), [r.topicIds["pricing"]!])
    }

    // MARK: Notebook

    func testNotebookPagesCiteTheCourseOrStayGeneral() throws {
        let r = try store.savePath(courseId: ids.hm, path([["Overbooking"]]), tier: "full", builtWith: nil)
        let topic = try XCTUnwrap(r.topicIds["overbooking"])
        let chunk = store.chunks(materialId: lecture)[0].id
        let svg = ##"<svg width="200" height="100" onload="alert(1)"><script>alert(2)</script><line x1="0" y1="0" x2="10" y2="10" stroke="red" onclick="x()"/><foreignObject><div>hi</div></foreignObject><text x="5" y="20" fill="#f00">Demand</text><image href="http://evil/x.png"/></svg>"##
        let w = try store.saveNotebook(courseId: ids.hm, [StudyStore.NotebookInput(key: "Overbooking", terms: [
            NotebookTerm(term: "Overbooking", definition: "Selling more rooms than exist.", courseWording: "Accepting more reservations than rooms.", sourceChunkIds: [chunk]),
            NotebookTerm(term: "No-show", definition: "A guest who doesn't arrive.", courseWording: "Made up.", sourceChunkIds: [99_999]),
        ], diagrams: [NotebookDiagram(title: "Booking curve", draw: "Bookings against days before arrival.", labels: ["capacity"], svg: svg),
                      NotebookDiagram(title: "Broken", draw: "Draw it.", svg: "<svg><script>")],
           formulas: [NotebookFormula(latex: "$RevPAR = ADR \\times Occ$", meaning: "Revenue per available room")])],
                                      tier: "full", generatedBy: "Claude Code")
        XCTAssertEqual(w.created, 1)
        let page = try XCTUnwrap(store.notebook(topicId: topic))
        XCTAssertEqual(page.terms[0].courseWording, "Accepting more reservations than rooms.")
        XCTAssertEqual(page.terms[0].locator, "slide 1")
        XCTAssertNil(page.terms[1].courseWording, "a course wording without a real source is dropped")
        XCTAssertTrue(w.warnings.contains { $0.contains("No-show") })
        let drawing = try XCTUnwrap(page.diagrams[0].svg)
        for bad in ["script", "onload", "onclick", "foreignObject", "image", "evil", "red", "#f00"] { XCTAssertFalse(drawing.contains(bad), bad) }
        XCTAssertTrue(drawing.contains("currentColor") && drawing.contains("Demand") && drawing.contains("viewBox=\"0 0 200.0 100.0\""), drawing)
        XCTAssertNil(page.diagrams[1].svg, "an unsafe drawing leaves what to draw")
        XCTAssertEqual(page.formulas[0].latex, "RevPAR = ADR \\times Occ")
        XCTAssertGreaterThanOrEqual(page.writingMinutes, 3)
        try store.setNotebookWritten(topic, written: true, page: "3")
        _ = try store.saveNotebook(courseId: ids.hm, [StudyStore.NotebookInput(topicId: topic, terms: [NotebookTerm(term: "Overbooking", definition: "New wording.")])],
                                   tier: "full", generatedBy: "Claude Code")
        XCTAssertEqual(store.topic(topic)?.notebookPage, "3", "rewriting the guide never touches the student's marks")
    }

    func testABasicNotebookNeverReplacesAFullOne() throws {
        let r = try store.savePath(courseId: ids.hm, path([["Overbooking"]]), tier: "full", builtWith: nil)
        let topic = r.topicIds["overbooking"]!
        _ = try store.saveNotebook(courseId: ids.hm, [StudyStore.NotebookInput(topicId: topic, terms: [NotebookTerm(term: "A", definition: "full")])], tier: "full", generatedBy: "x")
        let w = try store.saveNotebook(courseId: ids.hm, [StudyStore.NotebookInput(topicId: topic, terms: [NotebookTerm(term: "A", definition: "basic")])], tier: "basic", generatedBy: "y")
        XCTAssertEqual(w.skipped.count, 1)
        XCTAssertEqual(store.notebook(topicId: topic)?.terms.first?.definition, "full")
    }

    // MARK: Lessons

    func testLessonsNeedTheIdeaAndACitedCourseAngle() throws {
        let r = try store.savePath(courseId: ids.hm, path([["Overbooking"]]), tier: "full", builtWith: nil)
        let chunk = store.chunks(materialId: lecture)[0].id
        let w = try store.saveLessons(courseId: ids.hm, [
            StudyStore.LessonInput(key: "overbooking", preQuestion: "Why would a hotel sell more rooms than it has?", sections: [
                LessonSection(kind: "idea", title: "The idea", bodyMd: "Hotels overbook because some guests never arrive."),
                LessonSection(kind: "example", title: "Worked example", bodyMd: "100 rooms, 8% no-shows: sell about 108."),
                LessonSection(kind: "course_angle", title: "Your course's angle", bodyMd: "Your course frames it as a forecast.", sourceChunkIds: [chunk]),
                LessonSection(kind: "course_angle", title: "Uncited", bodyMd: "Your course says something.", sourceChunkIds: []),
                LessonSection(kind: "gossip", title: "?", bodyMd: "Not a kind."),
            ], checks: [CheckQuestion(prompt: "What's a no-show?", answer: "A guest who doesn't arrive.")],
               cards: [LessonCard(front: "Overbooking?", back: "Selling more rooms than exist, to cover no-shows.")], explainPrompt: "Explain overbooking to a new receptionist."),
            StudyStore.LessonInput(key: "missing", sections: [LessonSection(kind: "idea", title: "x", bodyMd: "y")]),
        ], tier: "full", generatedBy: "Claude Code")
        XCTAssertEqual(w.created, 1)
        XCTAssertEqual(w.skipped.count, 1)
        let lesson = try XCTUnwrap(store.lesson(topicId: r.topicIds["overbooking"]!))
        XCTAssertEqual(lesson.sections.map(\.kind), ["idea", "example", "course_angle"])
        XCTAssertEqual(lesson.cards.count, 1)
        XCTAssertTrue(w.warnings.contains { $0.contains("angle") })
        XCTAssertThrowsError(try store.saveLessons(courseId: ids.hm, Array(repeating: StudyStore.LessonInput(sections: []), count: 6), tier: "full", generatedBy: "x"))
        let noIdea = try store.saveLessons(courseId: ids.hm, [StudyStore.LessonInput(key: "overbooking", sections: [LessonSection(kind: "example", title: "x", bodyMd: "y")])],
                                           tier: "full", generatedBy: "x")
        XCTAssertEqual(noIdea.skipped.count, 1, "a lesson without its idea isn't a lesson")
    }

    // MARK: Skeleton

    func testWithoutAICoursesStillGetAPathAndANotebook() throws {
        let second = try FixtureFactory.pptx(slides: [(title: "Agenda", bullets: [], notes: nil, picture: nil, table: nil, chart: false),
                                                      (title: "Price elasticity", bullets: [(0, "x")], notes: nil, picture: nil, table: nil, chart: false)])
        let renamed = second.deletingLastPathComponent().appendingPathComponent("Week 4 – Demand and pricing.pptx")
        try FileManager.default.moveItem(at: second, to: renamed)
        guard case .imported = store.importMaterial(from: renamed, courseId: ids.hm) else { return XCTFail() }
        let r = try XCTUnwrap(try store.buildSkeletonPath(courseId: ids.hm))
        XCTAssertEqual(r.created, 2)
        let topics = store.topics(courseId: ids.hm)
        XCTAssertEqual(topics.map(\.title), ["Overbooking", "Demand and pricing"], "week 3 before week 4; titles without the week prefix")
        XCTAssertEqual(store.path(courseId: ids.hm)?.tier, "skeleton")
        let page = try XCTUnwrap(store.notebook(topicId: topics[1].id))
        XCTAssertEqual(page.terms.map(\.term), ["Price elasticity"], "boilerplate headings like Agenda are skipped")
        XCTAssertEqual(page.terms[0].locator, "slide 2")
        XCTAssertEqual(store.coverage(topicId: topics[0].id).map(\.materialId), [lecture])
        XCTAssertEqual(StudyStore.skeletonTitle("Lecture 05 - Revenue management (1)"), "Revenue management")
    }

    // MARK: Linking

    func testPracticeAndCardsFindTheirTopics() throws {
        let r = try store.savePath(courseId: ids.hm, path([["Overbooking and no-shows", "Price elasticity of demand"]]), tier: "full", builtWith: nil)
        let sheet = FixtureFactory.textPDF(pages: ["Exercise 1: Calculate the price elasticity of demand when price rises 10% and demand falls 5%.\nExercise 2: A hotel expects 8% no-shows; how many rooms should it overbook?"],
                                           name: "Tutorial 6.pdf")
        guard case .imported(let t, _) = store.importMaterial(from: sheet, courseId: ids.hm) else { return XCTFail() }
        try store.db.execute("INSERT INTO cards(course_id, material_id, front, back, due, fsrs_json) VALUES(?, ?, 'What is overbooking?', 'Selling rooms beyond capacity to cover no-shows.', '2026-10-01T00:00:00Z', '{}')", [ids.hm, lecture])
        XCTAssertEqual(store.linkPracticeAndCards(courseId: ids.hm), 3)
        let items = store.practiceItems(materialId: t)
        XCTAssertEqual(items.map(\.topicId), [r.topicIds["price-elasticity-of-demand"], r.topicIds["overbooking-and-no-shows"]])
        XCTAssertEqual(store.cards(courseId: ids.hm, status: nil).first?.topicId, r.topicIds["overbooking-and-no-shows"])
        XCTAssertEqual(store.linkCoverageByWords(materialId: lecture), 1)
        XCTAssertEqual(store.coverage(materialId: lecture).first?.topicId, r.topicIds["overbooking-and-no-shows"])
    }

    func testARebuiltPathRelinksWhatItsRetiredTopicsHeld() throws {
        let old = try store.savePath(courseId: ids.hm, path([["Overbooking and no-shows", "Price elasticity of demand"]]), tier: "skeleton", builtWith: nil)
        let sheet = FixtureFactory.textPDF(pages: ["Exercise 1: Calculate the price elasticity of demand when price rises 10% and demand falls 5%.\nExercise 2: A hotel expects 8% no-shows; how many rooms should it overbook?"],
                                           name: "Tutorial 6.pdf")
        guard case .imported(let t, _) = store.importMaterial(from: sheet, courseId: ids.hm) else { return XCTFail() }
        store.linkPracticeAndCards(courseId: ids.hm)
        XCTAssertEqual(store.practiceItems(materialId: t).compactMap(\.topicId).count, 2)
        XCTAssertEqual(store.linkCoverageByWords(materialId: lecture), 1)

        let new = try store.savePath(courseId: ids.hm, path([["Overbooking & no-shows", "Demand: price elasticity"]]), tier: "basic", builtWith: nil)
        XCTAssertEqual(new.retired, 2)
        XCTAssertTrue(store.practiceItems(materialId: t).allSatisfy { $0.topicId == nil }, "nothing points at a retired topic")
        XCTAssertTrue(store.coverage(topicId: old.topicIds["overbooking-and-no-shows"]!).isEmpty)
        store.linkPracticeAndCards(courseId: ids.hm)
        XCTAssertEqual(store.practiceItems(materialId: t).map(\.topicId), [new.topicIds["demand-price-elasticity"], new.topicIds["overbooking-no-shows"]])
        XCTAssertEqual(store.linkCoverageByWords(materialId: lecture), 1)
        XCTAssertEqual(store.coverage(materialId: lecture).map(\.topicId), [new.topicIds["overbooking-no-shows"]])
    }

    func testAFileFiledStraightIntoItsCourseReachesThePath() throws {
        try store.savePath(courseId: ids.hm, path([["Overbooking and no-shows"]]), tier: "full", builtWith: nil)
        XCTAssertEqual(store.path(courseId: ids.hm)?.stale, false)
        let deck = try FixtureFactory.pptx(slides: [(title: "Overbooking policy", bullets: [(0, "No-shows and walking guests")], notes: nil, picture: nil, table: nil, chart: false)])
        let named = deck.deletingLastPathComponent().appendingPathComponent("Lecture 5 – Overbooking policy.pptx")
        try FileManager.default.moveItem(at: deck, to: named)
        guard case .imported(let m, _) = store.importMaterial(from: named, courseId: ids.hm, role: .lecture) else { return XCTFail() }
        XCTAssertEqual(store.path(courseId: ids.hm)?.stale, true, "a Moodle sync's lecture marks the path for a rebuild")
        XCTAssertFalse(store.coverage(materialId: m).isEmpty)
    }

    func testMovingAFileTakesItsLinksToTheNewCourse() throws {
        let hm = try store.savePath(courseId: ids.hm, path([["Price elasticity of demand"]]), tier: "full", builtWith: nil)
        let mkt = try store.savePath(courseId: ids.mkt, path([["Price elasticity of demand"]]), tier: "full", builtWith: nil)
        let sheet = FixtureFactory.textPDF(pages: ["Exercise 1: Calculate the price elasticity of demand when price rises 10%.\nExercise 2: Calculate the price elasticity of demand when price falls 10%."],
                                           name: "Tutorial 7.pdf")
        guard case .imported(let t, _) = store.importMaterial(from: sheet, courseId: ids.hm) else { return XCTFail() }
        store.linkPracticeAndCards(courseId: ids.hm)
        XCTAssertEqual(Set(store.practiceItems(materialId: t).map(\.topicId)), [hm.topicIds["price-elasticity-of-demand"]])
        try store.confirmMaterial(t, courseId: ids.mkt)
        let items = store.practiceItems(materialId: t)
        XCTAssertEqual(Set(items.map(\.courseId)), [ids.mkt])
        XCTAssertEqual(Set(items.map(\.topicId)), [mkt.topicIds["price-elasticity-of-demand"]])
    }

    func testWords() {
        XCTAssertEqual(TopicLinker.words("Pricing strategies for the hotel"), ["pricing", "strategy", "hotel"])
        XCTAssertNil(TopicLinker.bestTopic(for: "unrelated words entirely", topics: [(1, ["pricing"])]))
    }
}

final class MasteryTests: XCTestCase {
    let now = ISO.parse("2026-10-07T12:00:00Z")!
    func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    func testFromNewToSolid() {
        XCTAssertEqual(MasteryRules.compute(MasteryInput(), now: now), .new)
        XCTAssertEqual(MasteryRules.compute(MasteryInput(notebookWritten: true), now: now), .familiar)
        XCTAssertEqual(MasteryRules.compute(MasteryInput(notebookWritten: true, lessonDone: true), now: now), .learning)
        let oneGot = [MasteryInput.Attempt(itemId: 1, rating: "got", at: day(1))]
        XCTAssertEqual(MasteryRules.compute(MasteryInput(lessonDone: true, attempts: oneGot), now: now), .learning, "one success alone isn't enough")
        XCTAssertEqual(MasteryRules.compute(MasteryInput(lessonDone: true, attempts: oneGot, explains: [.init(rating: "mostly", at: day(1))]), now: now), .practiced)
        let twoDays = oneGot + [MasteryInput.Attempt(itemId: 2, rating: "got", at: day(4))]
        XCTAssertEqual(MasteryRules.compute(MasteryInput(lessonDone: true, attempts: twoDays, explains: [.init(rating: "nailed", at: day(1))], cardRetrievability: 0.9), now: now), .solid)
        XCTAssertEqual(MasteryRules.compute(MasteryInput(lessonDone: true, attempts: twoDays, explains: [.init(rating: "nailed", at: day(1))], cardRetrievability: 0.8), now: now), .practiced,
                       "cards still slipping")
    }

    func testFading() {
        let attempts = [MasteryInput.Attempt(itemId: 1, rating: "got", at: day(40)), MasteryInput.Attempt(itemId: 2, rating: "got", at: day(35))]
        let explained = [MasteryInput.Check(rating: "nailed", at: day(35))]
        XCTAssertEqual(MasteryRules.compute(MasteryInput(lessonDone: true, attempts: attempts, explains: explained), now: now), .refresh, "a month without practice")
        let recent = [MasteryInput.Attempt(itemId: 1, rating: "got", at: day(3)), MasteryInput.Attempt(itemId: 2, rating: "got", at: day(1))]
        XCTAssertEqual(MasteryRules.compute(MasteryInput(lessonDone: true, attempts: recent, explains: [.init(rating: "nailed", at: day(1))], cardRetrievability: 0.6), now: now), .refresh)
        let shaky = MasteryInput(lessonDone: true, attempts: recent, explains: [.init(rating: "nailed", at: day(1))], notebookReviews: [.init(rating: "shaky", at: now)], cardRetrievability: 0.95)
        XCTAssertEqual(MasteryRules.compute(shaky, now: now), .refresh, "exam prep found it shaky")
    }
}

final class TextRepairTests: XCTestCase {
    func testLatexGetsItsBackslashesBack() {
        XCTAssertEqual(TextRepair.latex("TC = P \timesQ"), "TC = P \\timesQ")
        XCTAssertEqual(TextRepair.latex("MP = \u{0C}rac{\triangle Q}{\triangle L}"), "MP = \\frac{\\triangle Q}{\\triangle L}")
        XCTAssertEqual(TextRepair.latex("x \neq y \u{08}eta"), "x \\neq y \\beta")
    }

    func testMarkdownKeepsItsShapeAndLosesHTML() {
        XCTAssertEqual(TextRepair.markdown("<ul><li>Scarcity forces choices.</li><li>Opportunity <b>cost</b>.</li></ul>"),
                       "- Scarcity forces choices.\n- Opportunity **cost**.")
        XCTAssertEqual(TextRepair.markdown("Line one\nLine two with $a \times b$ and $x \neq y$"), "Line one\nLine two with $a \\times b$ and $x \\neq y$")
        XCTAssertEqual(TextRepair.markdown("Plain text\twith a tab"), "Plain text\twith a tab", "outside maths a tab is a tab")
    }
}

extension PathTests {
    func testTheCoursesWordingMustBeInTheSlideItCites() throws {
        let r = try store.savePath(courseId: ids.hm, path([["Overbooking"]]), tier: "basic", builtWith: nil)
        let chunk = store.chunks(materialId: lecture)[0].id
        let w = try store.saveNotebook(courseId: ids.hm, [StudyStore.NotebookInput(topicId: r.topicIds["overbooking"], terms: [
            NotebookTerm(term: "Overbooking", definition: "Selling more rooms than exist.", courseWording: "[chunk \(chunk) · slide 1] Overbooking: selling more rooms than exist", sourceChunkIds: [chunk]),
            NotebookTerm(term: "Equilibrium price", definition: "Where supply meets demand.", courseWording: "When does it occur? How to calculate it.", sourceChunkIds: [chunk]),
            NotebookTerm(term: "Overbooking", definition: "Sending a guest elsewhere.", courseWording: "Moving guests to a partner hotel at the hotel's cost", sourceChunkIds: [chunk]),
        ])], tier: "basic", generatedBy: "t")
        let terms = try XCTUnwrap(store.notebook(topicId: r.topicIds["overbooking"]!)).terms
        XCTAssertEqual(terms[0].courseWording, "Overbooking: selling more rooms than exist", "the copied chunk marker is dropped")
        XCTAssertNil(terms[1].courseWording, "a nearby question isn't a definition")
        XCTAssertNil(terms[2].courseWording, "words the slide doesn't contain")
        XCTAssertEqual(w.warnings.filter { $0.contains("isn't in the slides") }.count, 2)
    }
}
