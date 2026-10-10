import XCTest
@testable import StudyCore
@testable import StudyAI

final class EngineResolverTests: XCTestCase {
    let onDevice = EngineCandidate(ref: EngineRef("apple.ondevice"), free: true, contextTokens: 8_192, appleOnDevice: true)
    let pcc = EngineCandidate(ref: EngineRef("apple.pcc"), free: true, contextTokens: 32_000, appleCloud: true)
    let openRouter = EngineCandidate(ref: EngineRef("openrouter", model: "big:free"), free: true, contextTokens: 128_000)
    let ollama = EngineCandidate(ref: EngineRef("ollama", model: "qwen3"), free: true, contextTokens: 32_000, local: true)
    let anthropic = EngineCandidate(ref: EngineRef("anthropic", model: "claude-opus-5-5"), free: false, contextTokens: 1_000_000, strong: true)
    let groqPaid = EngineCandidate(ref: EngineRef("groq", model: "llama"), free: false, contextTokens: 131_072)

    func refs(_ task: AITask, _ i: EngineResolver.Inputs) -> [String] { EngineResolver.candidates(for: task, i).map(\.providerId) }

    func testBulkWorkPrefersTheOnDeviceModel() {
        let i = EngineResolver.Inputs(ready: [openRouter, ollama, pcc, onDevice])
        XCTAssertEqual(refs(.sortFiles, i), ["apple.ondevice", "apple.pcc", "ollama", "openrouter"], "free, private, no daily limit first")
    }

    func testWorkTheStudentReadsPrefersTheBestFreeModel() {
        let i = EngineResolver.Inputs(ready: [openRouter, ollama, pcc, onDevice])
        XCTAssertEqual(refs(.checkDraft, i), ["apple.pcc", "openrouter", "apple.ondevice", "ollama"])
    }

    func testTheStudentsOwnPickGoesFirstEvenAPaidOne() {
        let i = EngineResolver.Inputs(ready: [onDevice, groqPaid], everyday: EngineRef("groq"))
        XCTAssertEqual(refs(.sortFiles, i), ["groq", "apple.ondevice"])
        XCTAssertEqual(EngineResolver.candidates(for: .sortFiles, i).first?.model, "llama", "the engine's own model when the pick has none")
    }

    func testPaidEnginesStayOutOfEverydayWorkUnlessAllowed() {
        XCTAssertEqual(refs(.sortFiles, EngineResolver.Inputs(ready: [groqPaid, onDevice])), ["apple.ondevice"])
        XCTAssertEqual(refs(.sortFiles, EngineResolver.Inputs(ready: [groqPaid, onDevice], allowPaidEveryday: true)), ["apple.ondevice", "groq"])
    }

    func testAUsedUpFreeTierIsSkipped() {
        let i = EngineResolver.Inputs(ready: [openRouter, onDevice], exhausted: ["openrouter"])
        XCTAssertEqual(refs(.sortFiles, i), ["apple.ondevice"])
    }

    func testModelsTooSmallOrWithoutToolsAreSkipped() {
        let tiny = EngineCandidate(ref: EngineRef("lmstudio", model: "small"), free: true, contextTokens: 2_048, local: true)
        let noTools = EngineCandidate(ref: EngineRef("ollama", model: "plain"), free: true, contextTokens: 32_000, tools: false, local: true)
        XCTAssertEqual(refs(.sortFiles, EngineResolver.Inputs(ready: [tiny, noTools])), ["ollama"], "pipelines don't need tools")
        XCTAssertEqual(refs(.checkDraft, EngineResolver.Inputs(ready: [tiny, noTools])), [], "conversations do")
    }

    func testClaudeCodeIsNeverUsedForEverydayWork() {
        let i = EngineResolver.Inputs(ready: [onDevice], cliAvailable: true, everyday: .claudeCode)
        XCTAssertEqual(refs(.sortFiles, i), ["apple.ondevice"])
    }

    func testRetiredTasksNeverRun() {
        XCTAssertTrue(EngineResolver.candidates(for: .process, EngineResolver.Inputs(ready: [onDevice])).isEmpty)
    }

    func testTheOnDeviceModelNeverGrades() {
        let onDevice = EngineCandidate(ref: EngineRef("apple.ondevice"), free: true, contextTokens: 8_192, appleOnDevice: true)
        let online = EngineCandidate(ref: EngineRef("openrouter", model: "big:free"), free: true, contextTokens: 131_072)
        XCTAssertEqual(EngineResolver.candidates(for: .checkAnswer, .init(ready: [onDevice])), [], "no grading rather than wrong grading")
        XCTAssertEqual(EngineResolver.candidates(for: .checkAnswer, .init(ready: [onDevice, online])), [online.ref])
        XCTAssertEqual(EngineResolver.candidates(for: .sortFiles, .init(ready: [onDevice, online])).first, onDevice.ref, "sorting stays on device")
    }

    func testBuilderChoicesRoundTrip() {
        for c in [BuilderChoice.automatic, .claudeCode, .basicOnly, .engine(EngineRef("anthropic", model: "claude-opus-5-5"))] {
            XCTAssertEqual(BuilderChoice(setting: c.setting), c)
        }
        XCTAssertEqual(BuilderChoice(setting: "garbage|"), .engine(EngineRef("garbage")))
    }

    /// Every edition gets a working everyday engine from what's there: App Store (Apple's cloud model and the on-device
    /// model), the direct download (on-device, Claude Code for building), Windows and Linux (free online or Ollama).
    func testEachEditionHasAnEverydayPath() {
        let appStore = EngineResolver.Inputs(ready: [pcc, onDevice], cliAvailable: false)
        XCTAssertEqual(refs(.sortFiles, appStore).first, "apple.ondevice")
        let direct = EngineResolver.Inputs(ready: [onDevice], cliAvailable: true)
        XCTAssertEqual(refs(.sortFiles, direct), ["apple.ondevice"])
        let crossPlatform = EngineResolver.Inputs(ready: [openRouter, ollama])
        XCTAssertEqual(refs(.sortFiles, crossPlatform), ["ollama", "openrouter"])
    }
}

final class PracticeSplitterTests: XCTestCase {
    func testASolutionsPartGoesToItsProblemsByNumber() {
        let text = """
        Exercise 1: A 100-room hotel sold 82 rooms for 9,840. Calculate ADR, occupancy and RevPAR.

        Exercise 2: Explain why a single no-show rate for the whole hotel would mislead.

        Exercise 3: Should the hotel accept one more reservation when walking a guest costs 300?

        Solutions

        Solution 1: ADR = 9,840 / 82 = 120; occupancy 82%; RevPAR 98.40.
        Solution 3: Yes, while the expected walk cost stays below the room's revenue.
        """
        let items = PracticeSplitter.split(chunks([text]))
        XCTAssertEqual(items.map(\.number), ["1", "2", "3"])
        XCTAssertEqual(items[0].solution, "ADR = 9,840 / 82 = 120; occupancy 82%; RevPAR 98.40.")
        XCTAssertNil(items[1].solution)
        XCTAssertEqual(items[2].solution, "Yes, while the expected walk cost stays below the room's revenue.")
        XCTAssertFalse(items[2].prompt.contains("Solutions"), "the last problem stops where the solutions start")
    }

    func chunks(_ pages: [String]) -> [Chunk] {
        let store = try! makeStore()
        let ids = try! seedCourses(store)
        let pdf = FixtureFactory.textPDF(pages: pages, name: "Sheet.pdf")
        guard case .imported(let m, _) = store.importMaterial(from: pdf, courseId: ids.hm) else { XCTFail(); return [] }
        return store.chunks(materialId: m)
    }

    func testHeadingsInSeveralLanguages() {
        for (text, count) in [("Exercise 1: Calculate RevPAR for the hotel.\nExercise 2: Explain overbooking to a manager.", 2),
                              ("Aufgabe 1 Berechnen Sie den RevPAR des Hotels.\nAufgabe 2 Erklären Sie die Überbuchung genau.", 2),
                              ("Ejercicio 1. Calcula el RevPAR del hotel ahora.\nEjercicio 2. Explica la sobreventa al gerente.\nEjercicio 3. Compara ADR y RevPAR en detalle.", 3),
                              ("Q1. What is ADR in a hotel context?\nQ2. What is RevPAR in a hotel context?", 2)] {
            let items = PracticeSplitter.split(chunks([text]))
            XCTAssertEqual(items.count, count, text)
            XCTAssertEqual(items.first?.number, "1")
            XCTAssertEqual(items.first?.locator, "p. 1")
        }
    }

    func testNumberedListsWhenThereAreNoHeadings() {
        let items = PracticeSplitter.split(chunks(["Answer the following.\n1. What is occupancy in a hotel?\n2. What is the average daily rate?\n3. Why do hotels overbook?"]))
        XCTAssertEqual(items.map(\.number), ["1", "2", "3"], "the instructions before the first problem aren't a problem")
    }

    func testInlineSolutionsAndMarks() {
        let items = PracticeSplitter.split(chunks(["Question 1 (10 marks) Calculate RevPAR for 80% occupancy and ADR 120.\nSolution: RevPAR = 0.8 × 120 = 96.\nQuestion 2 (5 marks) Define overbooking in one sentence.\nAnswer: Selling more rooms than exist."]))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].marks, 10)
        XCTAssertTrue(items[0].prompt.contains("Calculate RevPAR"))
        XCTAssertFalse(items[0].prompt.contains("96"), "the answer is split off the problem")
        XCTAssertTrue(items[0].solution?.contains("96") ?? false)
        XCTAssertEqual(items[1].solution, "Selling more rooms than exist.")
    }

    func testASeparateSolutionsFileIsMatchedByNumber() {
        let problems = PracticeSplitter.split(chunks(["Exercise 1: Calculate RevPAR for the hotel.\nExercise 2: Explain overbooking to a manager."]))
        let answers = PracticeSplitter.split(chunks(["Exercise 1: RevPAR is 96 because 0.8 × 120.\nExercise 2: Hotels overbook to offset no-shows."]))
        let joined = PracticeSplitter.attachSolutions(problems, from: answers)
        XCTAssertEqual(joined[0].solution, "RevPAR is 96 because 0.8 × 120.")
        XCTAssertEqual(joined[1].solution, "Hotels overbook to offset no-shows.")
    }

    func testASolutionsFileWithBareHeadingsKeepsItsAnswers() {
        let problems = PracticeSplitter.split(chunks(["Question 1: Calculate RevPAR for the hotel.\nQuestion 2: Explain overbooking to a manager."]))
        let answers = PracticeSplitter.split(chunks(["Question 1\nAnswer: x=5\nQuestion 2\nAnswer: No-shows."]), answers: true)
        XCTAssertEqual(answers.map(\.number), ["1", "2"])
        let joined = PracticeSplitter.attachSolutions(problems, from: answers)
        XCTAssertEqual(joined.map(\.solution), ["x=5", "No-shows."])
        XCTAssertTrue(PracticeSplitter.split(chunks(["Question 1\nAnswer: x=5\nQuestion 2\nAnswer: No-shows."])).isEmpty, "as problems, they're too short")
    }

    func testAWorksheetWithoutNumbersIsOneProblem() {
        let items = PracticeSplitter.split(chunks(["SWOT analysis worksheet. Fill in the strengths, weaknesses, opportunities and threats for your hotel."]))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].number, "1")
    }

    func testMarksFormats() {
        XCTAssertEqual(PracticeSplitter.marks(in: "Explain (4 pts)"), 4)
        XCTAssertEqual(PracticeSplitter.marks(in: "Berechnen Sie [6 Punkte]"), 6)
        XCTAssertEqual(PracticeSplitter.marks(in: "Part a (2.5 marks)"), 2.5)
        XCTAssertNil(PracticeSplitter.marks(in: "Explain in 4 sentences"))
    }

    func testPracticeFilesSplitOnImportAndStopBeingPracticeWhenMoved() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let sheet = FixtureFactory.textPDF(pages: ["Exercise 1: Calculate RevPAR for the hotel.\nExercise 2: Explain overbooking to a manager."], name: "Tutorial 5.pdf")
        let answers = FixtureFactory.textPDF(pages: ["Exercise 1: RevPAR is 96.\nExercise 2: To offset no-shows."], name: "Tutorial 5 - Solutions.pdf")
        guard case .imported(let s, _) = store.importMaterial(from: sheet, courseId: ids.hm),
              case .imported(let a, _) = store.importMaterial(from: answers, courseId: ids.hm) else { return XCTFail() }
        XCTAssertEqual(store.practiceItems(materialId: s).count, 2)
        XCTAssertTrue(store.practiceItems(materialId: a).isEmpty, "a solutions file answers its sheet")
        XCTAssertEqual(store.practiceItems(materialId: s).first?.solutionMd, "RevPAR is 96.")
        let item = store.practiceItems(materialId: s)[0]
        try store.db.execute("INSERT INTO practice_attempts(item_id, self_rating) VALUES(?, 'got')", [item.id])
        try store.setFileGroup(s, .path)
        XCTAssertEqual(store.practiceItems(materialId: s).map(\.id), [item.id], "a problem the student attempted is kept")
        try store.setFileGroup(s, .practice)
        XCTAssertEqual(store.practiceItems(materialId: s).count, 2)
    }

    func testSolutionsThatArriveBeforeTheirSheetStopBeingProblems() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let answers = FixtureFactory.textPDF(pages: ["Exercise 1: RevPAR is 96 because 0.8 × 120.\nExercise 2: To offset expected no-shows."], name: "Tutorial 5 - Solutions.pdf")
        let sheet = FixtureFactory.textPDF(pages: ["Exercise 1: Calculate RevPAR for the hotel.\nExercise 2: Explain overbooking to a manager."], name: "Tutorial 5.pdf")
        guard case .imported(let a, _) = store.importMaterial(from: answers, courseId: ids.hm) else { return XCTFail() }
        XCTAssertEqual(store.practiceItems(materialId: a).count, 2, "with no sheet yet, its answers are all there is")
        guard case .imported(let s, _) = store.importMaterial(from: sheet, courseId: ids.hm) else { return XCTFail() }
        XCTAssertTrue(store.practiceItems(materialId: a).isEmpty, "once paired, the answers aren't problems")
        XCTAssertEqual(store.practiceItems(materialId: s).first?.solutionMd, "RevPAR is 96 because 0.8 × 120.")
    }
}
