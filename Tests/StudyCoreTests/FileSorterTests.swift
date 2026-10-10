import XCTest
@testable import StudyCore

final class FileSorterTests: XCTestCase {
    func sort(_ filename: String, title: String = "", text: String = "", section: String? = nil, module: String? = nil,
              kind: String = "pdf") -> FileSorter.Result {
        FileSorter.sort(.init(filename: filename, title: title, text: text, sectionName: section, moduleName: module, kind: kind))
    }
    func role(_ filename: String, text: String = "", section: String? = nil, module: String? = nil, kind: String = "pdf") -> MaterialRole {
        sort(filename, text: text, section: section, module: module, kind: kind).role
    }

    /// What the v5 rules got right still holds.
    func testOldGuessesStillHold() {
        XCTAssertEqual(role("HM210 Course Outline.pdf"), .syllabus)
        XCTAssertEqual(role("Marking rubric report.docx"), .rubric)
        XCTAssertEqual(role("Past paper 2024.pdf"), .pastExam)
        XCTAssertEqual(role("Assignment brief.pdf"), .brief)
        XCTAssertEqual(role("Week 3 slides.pptx", kind: "slides"), .lecture)
    }

    /// v5 called every one of these a lecture.
    func testPracticeInManyLanguages() {
        for name in ["Tutorial 4.pdf", "Exercise sheet 2.pdf", "Problem Set 3.pdf", "PS4.pdf", "HW3 questions.pdf", "Worksheet - pricing.docx",
                     "Übungsblatt 3.pdf", "Uebung_05.pdf", "Tutorium Woche 2.pdf", "TD2 - Elasticité.pdf", "Exercices chapitre 4.pdf",
                     "Ejercicios tema 3.pdf", "Esercitazione 2.pdf", "Werkcollege 4 opgaven.pdf", "Lista de exercícios 2.pdf"] {
            XCTAssertEqual(role(name), .practice, name)
            XCTAssertGreaterThanOrEqual(sort(name).confidence, FileSorter.sureEnough, name)
        }
    }

    func testSolutionsAreMarkedAndPairWithTheirSheet() {
        let solutions = sort("Lösungen Übung 2.pdf")
        XCTAssertEqual(solutions.role, .practice)
        XCTAssertTrue(solutions.isSolutions)
        XCTAssertFalse(sort("Übung 2.pdf").isSolutions)
        XCTAssertEqual(FileSorter.pairKey("Tutorial 3 – Solutions.pdf"), FileSorter.pairKey("Tutorial 3.pdf"))
        XCTAssertEqual(FileSorter.pairKey("Lösungen Übung 2.pdf"), FileSorter.pairKey("Übung 2.pdf"))
        XCTAssertEqual(FileSorter.pairKey("Tutorial 3 - Model Answers.pdf"), "tutorial 3", "the whole phrase goes, not just its last word")
        XCTAssertEqual(FileSorter.pairKey("Tutorial 3 Worked Solutions.pdf"), "tutorial 3")
        XCTAssertEqual(FileSorter.pairKey("Tutorial 3 Answer Key.pdf"), "tutorial 3")
        let exam = sort("Midterm 2023 solutions.pdf")
        XCTAssertEqual(exam.role, .pastExam, "answers to an exam stay with exams")
        XCTAssertTrue(exam.isSolutions)
        XCTAssertEqual(role("TD2 corrigé.pdf"), .practice)
    }

    func testExamplesExamsAndAdmin() {
        XCTAssertEqual(role("In-class examples week 4.pdf"), .example)
        XCTAssertEqual(role("Worked example - forecasting.pdf"), .example)
        XCTAssertEqual(role("Midterm 2023.pdf"), .pastExam)
        XCTAssertEqual(role("Altklausur WS2324.pdf"), .pastExam)
        XCTAssertEqual(role("Tentamen 2022.pdf"), .pastExam)
        XCTAssertEqual(role("Attendance list.pdf"), .other)
        XCTAssertEqual(role("Room change week 5.pdf"), .other)
        XCTAssertEqual(MaterialRole.other.group, .notUsed)
    }

    func testLecturesStayLectures() {
        XCTAssertEqual(role("Lecture 5 - Pricing.pptx", kind: "slides"), .lecture)
        XCTAssertEqual(role("Focus groups in market research.pptx", kind: "slides"), .lecture, "a topic, not a group list")
        XCTAssertEqual(role("Common problems in hotel pricing.pptx", kind: "slides"), .lecture, "a topic, not a problem set")
        XCTAssertEqual(role("Vorlesung 3.pdf"), .lecture)
        XCTAssertEqual(role("Exam review session.pptx", kind: "slides"), .lecture)
        XCTAssertEqual(role("Case study - Marriott.pdf"), .reading)
    }

    func testMoodleSectionDecidesWhenTheNameCant() {
        let r = sort("file3.pdf", section: "Tutorials")
        XCTAssertEqual(r.role, .practice)
        XCTAssertTrue(r.fromMoodle)
        XCTAssertEqual(r.source, "moodle")
        XCTAssertTrue(r.reason.contains("Tutorials"), r.reason)
        XCTAssertEqual(role("Week 3.pdf", section: "Week 3 – Pricing", module: "Pricing exercises"), .practice)
        XCTAssertEqual(role("Slides.pdf", section: "Past exams"), .lecture, "the file's own name beats its section")
    }

    func testContentDecidesWhenNamesSayNothing() {
        let exam = "Time allowed: 2 hours. Answer ALL questions. Question 1 (20 marks) Explain overbooking. Total marks: 100"
        XCTAssertEqual(role("HM210.pdf", text: exam), .pastExam)
        let sheet = "Exercise 1: Calculate RevPAR. Exercise 2: Compute the ADR. Exercise 3: Determine occupancy. Exercise 4: Find the break-even."
        XCTAssertEqual(role("Week 2.pdf", text: sheet), .practice)
        let outline = "Learning outcomes: price rooms. Assessment: Exam 60%, Project 40%."
        XCTAssertEqual(role("HM210 info.pdf", text: outline), .syllabus)
        let article = "Abstract. We study pricing. Introduction ... References: Smith et al. (2020), Journal of Revenue."
        XCTAssertEqual(role("smith2020.pdf", text: article), .reading)
    }

    /// Names from a real course folder that the first version of these rules missed.
    func testNamesFromARealCourseFolder() {
        XCTAssertEqual(role("SWOTAnalysisWorksheet.pdf"), .practice, "CamelCase is split into words")
        XCTAssertEqual(role("Quiz about EEO, Aff Act BFOQ BN.docx"), .practice)
        let key = sort("Adichie literary devices KEY.docx")
        XCTAssertTrue(key.isSolutions, "an uppercase KEY is an answer key")
        XCTAssertFalse(sort("Key concepts in marketing.pptx", kind: "slides").isSolutions)
        XCTAssertTrue(sort("1. Catch up exercise 2026.2 - Solved.docx").isSolutions)
        XCTAssertEqual(FileSorter.pairKey("1. Catch up exercise 2026.2 - Solved.docx"), FileSorter.pairKey("1. Catch up exercise 2026.2.docx"))
        XCTAssertEqual(role("BHC1-09-158Marketing for the Hospitality Industry SOW 2026.2.pdf"), .syllabus)
        XCTAssertEqual(role("MKT OUTLINE PROJECT BBA3 26.2.docx"), .brief)
        XCTAssertEqual(role("Job description and person specification template.pdf"), .other)
        XCTAssertTrue(sort("4 SM Connectors key.docx").isSolutions, "a name ending in key is an answer key")
        XCTAssertEqual(role("4 SM Connectors key.docx"), .practice)
        XCTAssertEqual(role("Week 11 ChatGPT analysis activity.docx", text: "Week 11. Chat GPT analysis activity. Task 1: read. Task 2: compare."), .practice)
    }

    func testNoCluesIsUnsureExceptForSlides() {
        let pdf = sort("doc_8812.pdf")
        XCTAssertFalse(pdf.isSure, "goes to free AI, then Needs a look")
        let deck = sort("deck.pptx", kind: "slides")
        XCTAssertEqual(deck.role, .lecture)
        XCTAssertTrue(deck.isSure)
        XCTAssertFalse(sort("Exam info.pdf").isSure)
    }

    func testReasonsReadLikeASentence() {
        XCTAssertEqual(sort("Tutorial 4.pdf").reason, "The name says “Tutorial”.")
        XCTAssertEqual(sort("HRDiversity SOW 2026.2.pdf").reason, "The name says “SOW”.", "the file's own spelling")
        XCTAssertEqual(sort("Lösungen_Übung_2.pdf").reason, "The name says “Übung”.")
        XCTAssertTrue(sort("x.pdf", module: "Tutorial 4 · Solutions").reason.hasPrefix("Moodle lists it as"))
    }
}

final class TaughtDateTests: XCTestCase {
    func testWeekAndSessionNumbers() {
        XCTAssertEqual(TaughtDate.week(in: "Week 3 – Pricing"), 3)
        XCTAssertEqual(TaughtDate.week(in: "W03_slides"), 3)
        XCTAssertEqual(TaughtDate.week(in: "Woche 3"), 3)
        XCTAssertEqual(TaughtDate.week(in: "Semaine 12"), 12)
        XCTAssertNil(TaughtDate.week(in: "Week 99"))
        XCTAssertNil(TaughtDate.week(in: "Weekly reading"))
        XCTAssertEqual(TaughtDate.session(in: "Lecture 5 - Pricing"), 5)
        XCTAssertEqual(TaughtDate.session(in: "L05"), 5)
        XCTAssertEqual(TaughtDate.session(in: "Sesión 4"), 4)
        XCTAssertEqual(TaughtDate.session(in: "Vorlesung 2"), 2)
        XCTAssertNil(TaughtDate.session(in: "Tutorial 3"))
    }

    func testDates() {
        let start = d("2026-09-07") // a Monday
        XCTAssertEqual(TaughtDate.date(texts: ["Week 3"], termStart: start, classDates: []), d("2026-09-21"))
        XCTAssertEqual(TaughtDate.date(texts: ["Week 3"], termStart: start, classDates: [d("2026-09-15"), d("2026-09-23")]), d("2026-09-23"),
                       "the course's class that week")
        XCTAssertEqual(TaughtDate.date(texts: [nil, "Lecture 2"], termStart: start,
                                       classDates: [d("2026-09-08"), d("2026-09-10"), d("2026-09-15")]), d("2026-09-10"))
        XCTAssertNil(TaughtDate.date(texts: ["Pricing.pdf"], termStart: start, classDates: [d("2026-09-08")]),
                     "an import date is not a teaching date")
        XCTAssertEqual(TaughtDate.date(texts: ["Week 2 – Demand", "Lecture 5"], termStart: start, classDates: []), d("2026-09-14"),
                       "the section comes first")
    }
}

final class FileImportTests: XCTestCase {
    func deck(_ name: String) throws -> URL {
        let url = try FixtureFactory.pptx(slides: [(title: "Overbooking", bullets: [(0, "No-shows")], notes: nil, picture: nil, table: nil, chart: false)])
        let renamed = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: renamed)
        return renamed
    }

    func testAClearCourseIsFiledWithoutAsking() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let file = try deck("HM210 Week 3 - Overbooking.pptx")
        let copy = file.deletingLastPathComponent().appendingPathComponent("copy").appendingPathComponent(file.lastPathComponent)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: copy)   // importing moves the original away
        guard case .imported(let id, _) = store.importMaterial(from: file) else { return XCTFail() }
        let m = try XCTUnwrap(store.material(id))
        XCTAssertEqual(m.courseId, ids.hm)
        XCTAssertEqual(m.status, "ready")
        XCTAssertTrue(m.storedPath!.contains("/HM210/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.absolute(m.storedPath!).path))
        XCTAssertEqual(m.role, .lecture)
        XCTAssertEqual(m.roleSource, "auto")
        XCTAssertEqual(m.taughtOn, d("2026-09-21"), "week 3 of a term starting 7 September")
        XCTAssertTrue(store.needsLook().isEmpty)
        guard case .duplicate(let again, _) = store.importMaterial(from: copy) else { return XCTFail("the same bytes again are a duplicate") }
        XCTAssertEqual(again, id)
    }

    func testAnUnclearCourseWaitsInNeedsALook() throws {
        let store = try makeStore()
        try seedCourses(store)
        let pdf = FixtureFactory.textPDF(pages: ["Some notes about something."], name: "Notes.pdf")
        guard case .imported(let id, _) = store.importMaterial(from: pdf) else { return XCTFail() }
        XCTAssertNil(store.material(id)?.courseId)
        XCTAssertEqual(store.needsLook().map(\.kind), [.unfiledFile])
        XCTAssertEqual(store.needsLookCount(), 1)
    }

    func testTheOnlyCourseThisTermIsClear() throws {
        let store = try makeStore()
        let term = try store.ensureCurrentTerm(today: d("2026-10-07"))
        let course = try store.saveCourse(Course(termId: term.id, code: "FIN220", name: "Corporate Finance"))
        let pdf = FixtureFactory.textPDF(pages: ["Bond pricing"], name: "Notes.pdf")
        guard case .imported(let id, _) = store.importMaterial(from: pdf) else { return XCTFail() }
        XCTAssertEqual(store.material(id)?.courseId, course)
    }

    func testSolutionsPairWithTheirSheetWhicheverComesFirst() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let answers = FixtureFactory.textPDF(pages: ["Solution 1: 80. Solution 2: 120."], name: "Tutorial 3 - Solutions.pdf")
        let sheet = FixtureFactory.textPDF(pages: ["Exercise 1: calculate RevPAR. Exercise 2: compute ADR."], name: "Tutorial 3.pdf")
        guard case .imported(let a, _) = store.importMaterial(from: answers, courseId: ids.hm),
              case .imported(let s, _) = store.importMaterial(from: sheet, courseId: ids.hm) else { return XCTFail() }
        XCTAssertEqual(store.material(a)?.role, .practice)
        XCTAssertEqual(store.material(s)?.role, .practice)
        XCTAssertEqual(store.material(a)?.pairsWith, s)
        XCTAssertNil(store.material(s)?.pairsWith)
    }

    func testTheStudentsGroupIsFinal() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        guard case .imported(let id, _) = store.importMaterial(from: try deck("Week 2 - Demand.pptx"), courseId: ids.hm) else { return XCTFail() }
        try store.setFileGroup(id, .notUsed)
        var m = try XCTUnwrap(store.material(id))
        XCTAssertTrue(m.excluded)
        XCTAssertEqual(m.group, .notUsed)
        XCTAssertEqual(m.readState, "skipped")
        try store.setFileGroup(id, .practice)
        m = try XCTUnwrap(store.material(id))
        XCTAssertFalse(m.excluded)
        XCTAssertEqual(m.role, .practice)
        XCTAssertEqual(m.roleSource, "user")
        XCTAssertEqual(m.readState, "done", "its problems are split out straight away, without AI")
        XCTAssertFalse(store.practiceItems(materialId: id).isEmpty)
        try store.applySort(id, role: .lecture, confidence: 0.99, reason: "AI", source: "ai")
        XCTAssertEqual(store.material(id)?.role, .practice, "nothing automatic overrides the student")
        store.addHints(id, ImportHints(sectionName: "Lectures"))
        XCTAssertEqual(store.material(id)?.role, .practice)
    }

    func testUnsureFilesAskOnceAndThenStayQuiet() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let pdf = FixtureFactory.textPDF(pages: ["General remarks that say nothing about what kind of document this is."], name: "doc_8812.pdf")
        guard case .imported(let id, _) = store.importMaterial(from: pdf, courseId: ids.hm) else { return XCTFail() }
        XCTAssertEqual(store.needsLook().map(\.kind), [.unsureFile])
        try store.confirmSort(id)
        XCTAssertTrue(store.needsLook().isEmpty)
    }

    func testMoodleHintsFixAGuessButNotAnOldRole() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let pdf = FixtureFactory.textPDF(pages: ["General remarks that say nothing about what kind of document this is."], name: "file3.pdf")
        guard case .imported(let id, _) = store.importMaterial(from: pdf, courseId: ids.hm) else { return XCTFail() }
        XCTAssertEqual(store.material(id)?.role, .lecture)
        store.addHints(id, ImportHints(sectionName: "Week 4", moduleName: "Tutorial 4"))
        let m = try XCTUnwrap(store.material(id))
        XCTAssertEqual(m.role, .practice)
        XCTAssertEqual(m.roleSource, "moodle")
        XCTAssertEqual(m.sectionName, "Week 4")
        XCTAssertEqual(m.taughtOn, d("2026-09-28"))
    }

    func testFilesFromBeforeV6AreResortedOnceWhenTheRulesAreSure() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        func legacy(_ name: String, title: String? = nil, role: String, hash: String) throws -> Int {
            try store.db.execute("""
                INSERT INTO materials(course_id, title, kind, role, role_source, original_filename, content_hash, status)
                VALUES(?, ?, 'pdf', ?, 'legacy', ?, ?, 'ready')
                """, [ids.hm, title ?? name, role, name + ".pdf", hash]).lastInsertId
        }
        let tutorial = try legacy("Tutorial 2", role: "lecture", hash: "a")
        let lecture = try legacy("Lecture 1 - Intro", role: "lecture", hash: "b")
        let reading = try legacy("Exercises", role: "reading", hash: "c")
        let unclear = try legacy("scan 0042", role: "lecture", hash: "d")
        let chapterProblems = try legacy("PROBLEM TOPIC 1 Solutions", title: "PROBLEM CHAPTER 1", role: "reading", hash: "e")
        XCTAssertEqual(store.resortFiles(), 2)
        XCTAssertEqual(store.material(tutorial)?.role, .practice)
        XCTAssertEqual(store.material(lecture)?.role, .lecture)
        XCTAssertEqual(store.material(reading)?.role, .reading, "the old rules never made this a reading: the student did")
        XCTAssertEqual(store.material(chapterProblems)?.role, .practice, "a reading only because its name said \"chapter\"")
        XCTAssertEqual(store.material(unclear)?.role, .lecture)
        XCTAssertEqual(store.material(unclear)?.roleSource, "auto")
        XCTAssertTrue(store.needsLook().isEmpty, "old files never flood Needs a look")
        XCTAssertEqual(store.resortFiles(), 0, "runs once per version of the rules")
        try store.setFileGroup(tutorial, .path)
        store.setSetting("file_rules_version", "1")
        XCTAssertEqual(store.resortFiles(), 0, "new rules never override the student")
        XCTAssertEqual(store.material(tutorial)?.role, .lecture)
    }

    func testNeedsALookCountsEveryKindOnce() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        try store.db.execute("INSERT INTO assignments(course_id, title, confirmed, source) VALUES(?, 'Pricing report', 0, 'claude')", [ids.hm])
        try store.db.execute("""
            INSERT INTO cards(course_id, front, back, due, fsrs_json, status, created_by) VALUES(?, 'ADR?', 'Average daily rate', '2026-10-01T00:00:00Z', '{}', 'proposed', 'claude'),
              (?, 'RevPAR?', 'ADR × occupancy', '2026-10-01T00:00:00Z', '{}', 'proposed', 'claude')
            """, [ids.hm, ids.hm])
        let items = store.needsLook()
        XCTAssertEqual(items.map(\.kind), [.proposedDeadline, .oldProposedCards])
        XCTAssertEqual(items[1].title, "2 suggested flashcards from before the update")
        XCTAssertEqual(store.needsLookCount(), items.count)
        try store.resolveOldProposedCards(keep: true)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM cards WHERE status = 'active'"), 2)
        XCTAssertEqual(store.needsLookCount(), 1)
    }

    func testEnsureCurrentTerm() throws {
        let store = try makeStore()
        let fall = try store.ensureCurrentTerm(today: d("2026-10-07"))
        XCTAssertEqual(fall.name, "Fall 2026")
        XCTAssertEqual(fall.startDate, d("2026-08-15"))
        XCTAssertEqual(fall.endDate, d("2027-01-31"))
        XCTAssertEqual(try store.ensureCurrentTerm(today: d("2027-03-01")).id, fall.id, "an existing current term is kept")
        let other = try makeStore()
        XCTAssertEqual(try other.ensureCurrentTerm(today: d("2027-03-01")).name, "Spring 2027")
        XCTAssertEqual(try makeStore().ensureCurrentTerm(today: d("2027-01-10")).name, "Fall 2026")
    }
}
