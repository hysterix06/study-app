import XCTest
@testable import StudyCore
@testable import StudyMCPCore
@testable import StudyAI

// Diagrams, slide condensing and the lean Claude Code engine. Fixtures are Markdown and direct database
// rows only, so these run on every platform.

private func notesStore() throws -> (StudyStore, course: Int) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("st-notes-\(UUID().uuidString)")
    let store = try StudyStore.open(paths: AppPaths(database: root.appendingPathComponent("study.db"), root: root.appendingPathComponent("files")))
    store.setSetting("default_timezone", "Europe/Madrid")
    let term = try store.saveTerm(Term(name: "Fall 2026", startDate: LocalDate("2026-09-07")!, endDate: LocalDate("2026-12-18")!, isCurrent: true))
    let course = try store.saveCourse(Course(termId: term, code: "EC101", name: "Microeconomics", color: "ocean"))
    return (store, course)
}

final class DiagramTests: XCTestCase {
    let supplyDemand: [String: Any] = [
        "kind": "graph", "title": "Equilibrium", "x_label": "Quantity", "y_label": "Price",
        "curves": [["label": "S", "points": [[1, 1], [9, 9]]], ["label": "D", "points": [[1, 9], [9, 1]]],
                   ["label": "bad", "points": [[1, 1]]]],
        "points": [["label": "E", "x": 5, "y": 5, "x_tick": "Q*", "y_tick": "P*"]],
        "areas": [["label": "CS", "points": [[0, 9.5], [0, 5], [5, 5]]]],
        "arrows": [["label": "shift", "from": [6, 4], "to": [7, 5]]],
    ]

    func testParseKeepsValidPartsAndReportsTheRest() {
        let (d, warnings) = Diagram.parse(supplyDemand)
        let g = try! XCTUnwrap(d)
        XCTAssertEqual(g.kind, .graph)
        XCTAssertEqual(g.curves.map(\.label), ["S", "D"], "a one-point curve is dropped")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(g.markers.first?.xTick, "Q*")
        XCTAssertEqual(g.areas.count, 1)
        XCTAssertEqual(g.arrows.count, 1)
        XCTAssertEqual(g.summary, "Equilibrium: Price against Quantity: curves S, D: points E: shaded CS: shifts shift")
    }

    func testParseClampsAndAcceptsLooseNumbers() {
        let (d, _) = Diagram.parse(["kind": "graph", "curves": [["label": "S", "points": [["1", "2"], [500, -3]]]]])
        XCTAssertEqual(d?.curves.first?.points, [DPoint(1, 2), DPoint(11, 0)], "kept on the grid")
        XCTAssertNil(Diagram.parse(["kind": "graph"]).diagram, "nothing to draw")
        XCTAssertNil(Diagram.parse(["kind": "flow", "steps": ["only one"]]).diagram)
        XCTAssertNil(Diagram.parse("not an object").diagram)
        XCTAssertEqual(Diagram.parse(["steps": ["Plan", "Do", "Check"], "cycle": true]).diagram?.kind, .flow, "kind inferred from steps")
    }

    func testLayoutPutsTheGridInsideThePlot() {
        let d = Diagram.parse(supplyDemand).diagram!
        let shapes = DiagramLayout.shapes(d, width: 480, height: DiagramLayout.height(d, width: 480))
        let texts = shapes.compactMap { s -> String? in if case .text(let t, _, _, _, _) = s { return t }; return nil }
        for label in ["Equilibrium", "Quantity", "Price", "S", "D", "E", "Q*", "P*", "CS", "shift"] { XCTAssertTrue(texts.contains(label), label) }
        var curveStarts: [DPoint] = []
        for s in shapes { if case .line(let start, _, _, .curve) = s { curveStarts.append(start) } }
        XCTAssertEqual(curveStarts.count, 2)
        // (1, 1) and (1, 9) share x and sit above/below each other.
        XCTAssertEqual(curveStarts[0].x, curveStarts[1].x, accuracy: 0.001)
        XCTAssertGreaterThan(curveStarts[0].y, curveStarts[1].y, "y grows downward on screen")
    }

    func testSmoothCurvesPassThroughTheirPoints() {
        let pts = [DPoint(0, 0), DPoint(10, 20), DPoint(20, 0), DPoint(30, 20)]
        let segs = DiagramLayout.bezier(pts)
        XCTAssertEqual(segs.map(\.end), Array(pts.dropFirst()))
    }

    func testFlowWrapsIntoRows() {
        let d = Diagram(kind: .flow, steps: ["Forecast demand", "Set rates", "Open inventory", "Monitor pickup", "Adjust price"], cycle: true)
        let boxes = DiagramLayout.shapes(d, width: 480, height: DiagramLayout.height(d, width: 480)).compactMap { s -> DPoint? in
            if case .box(let o, _, _) = s { return o }; return nil
        }
        XCTAssertEqual(boxes.count, 5)
        XCTAssertEqual(Set(boxes.map(\.y)).count, 2, "four per row, then a second row")
        // The way back from the last step runs outside every box.
        let shapes = DiagramLayout.shapes(d, width: 480, height: DiagramLayout.height(d, width: 480))
        let frames = shapes.compactMap { s -> CGRectLike? in if case .box(let o, let w, let h) = s { return CGRectLike(o: o, w: w, h: h) }; return nil }
        guard case .line(let start, let points, _, _)? = shapes.last(where: { if case .line = $0 { return true }; return false }) else { return XCTFail() }
        let path = [start] + points
        for (a, b) in zip(path, path.dropFirst()) {
            for f in frames.dropFirst() where f.crosses(a, b) { XCTFail("the cycle's way back crosses a box at \(f.o)") }
        }
        XCTAssertLessThanOrEqual(path.map(\.y).max() ?? 0, DiagramLayout.height(d, width: 480), "it fits the diagram's height")
        XCTAssertEqual(DiagramLayout.wrap("Households supply labour to firms", width: 60, lines: 2).count, 2)
    }

    func testSVGIsStaticAndEscaped() {
        let d = Diagram(kind: .flow, title: "<script>alert(1)</script>", steps: ["A & B", "\"C\""])
        let svg = DiagramSVG.render(d)
        XCTAssertTrue(svg.hasPrefix("<svg"))
        XCTAssertFalse(svg.contains("<script"))
        XCTAssertTrue(svg.contains("A &amp; B"))
    }

    func testCodableRoundTrip() throws {
        let d = Diagram.parse(supplyDemand).diagram!
        let back = try JSONDecoder().decode(Diagram.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
        XCTAssertEqual(Diagram.parse(d.jsonObject).diagram, d, "the loose form reads back the same")
    }
}

final class CondenserTests: XCTestCase {
    func chunk(_ id: Int, _ text: String, heading: String? = nil, notes: String? = nil) -> Chunk {
        Chunk(id: id, materialId: 1, ordinal: id, locator: "slide \(id)", heading: heading, textMd: text, notesMd: notes)
    }

    func testDropsFootersFillerAndRepeats() {
        let footer = "EC101 Microeconomics · Autumn 2026"
        let chunks = [
            chunk(1, "Agenda\nDemand\nSupply\n\(footer)\n1"),
            chunk(2, "Demand slopes down\nLaw of demand\n\(footer)\n2", heading: "Demand"),
            chunk(3, "Supply slopes up\n\(footer)\n3", heading: "Supply"),
            chunk(4, "Agenda\nDemand\nSupply\n\(footer)\n4"),
            chunk(5, "Thank you!\n\(footer)\n5"),
            chunk(6, "Questions?\n\(footer)", notes: "Remind them about the quiz on Friday"),
        ]
        let r = MaterialCondenser.condense(chunks)
        XCTAssertEqual(r.chunks.map(\.id), [1, 2, 3, 6], "repeated agenda and the thank-you slide go")
        XCTAssertFalse(r.chunks.contains { $0.textMd.contains(footer) }, "footer stripped everywhere")
        XCTAssertFalse(r.chunks[1].textMd.hasSuffix("2"), "slide numbers stripped")
        XCTAssertEqual(r.dropped, 2)
        XCTAssertLessThan(r.tokensAfter, r.tokensBefore)
    }

    func testNeverReturnsNothingAndKeepsUntouchedEstimates() {
        let noise = [chunk(1, "Thank you"), chunk(2, "Questions?")]
        XCTAssertEqual(MaterialCondenser.condense(noise).chunks.map(\.id), [1, 2])
        let c = Chunk(id: 9, materialId: 1, ordinal: 1, locator: "p. 1", textMd: "Elasticity measures responsiveness.", tokenEstimate: 1500)
        XCTAssertEqual(MaterialCondenser.condense([c]).chunks.first?.tokenEstimate, 1500)
        // A slide that repeats its title loses that line; its estimate shrinks in proportion, and indentation stays.
        let slide = Chunk(id: 10, materialId: 1, ordinal: 2, locator: "slide 2", heading: "Elasticity",
                          textMd: "## Elasticity\n- Responsiveness\n  - of quantity to price", tokenEstimate: 1500)
        let kept = MaterialCondenser.condense([slide]).chunks[0]
        XCTAssertEqual(kept.textMd, "- Responsiveness\n  - of quantity to price")
        XCTAssertLessThan(kept.tokenEstimate, 1500)
        XCTAssertGreaterThan(kept.tokenEstimate, 1000)
    }
}

final class ClaudeCodeProviderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A stand-in `claude` that records its arguments and stdin, optionally rejects a flag, and answers in JSON.
    func fakeCLI(reject: String? = nil, reply: String = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"ok\":true}","num_turns":1,"usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":500,"output_tokens":400}}"#) throws -> URL {
        let script = dir.appendingPathComponent("claude")
        var body = "#!/bin/sh\n"
        if let reject { body += "case \" $* \" in *\" \(reject) \"*) echo \"error: unknown option '\(reject)'\" >&2; exit 1;; esac\n" }
        body += "for a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"\(dir.path)/args.txt\"\ncat > \"\(dir.path)/stdin.txt\"\ncat <<'JSON'\n\(reply)\nJSON\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func args() throws -> [String] { try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8).components(separatedBy: "\n") }

    func testOneShotRequestIsLean() async throws {
        let p = ClaudeCodeProvider(cli: try fakeCLI(), workingDirectory: dir.appendingPathComponent("work"))
        let r = try await p.send(ChatRequest(model: "sonnet", messages: [.system("Rules."), .user("The slides…")],
                                             responseSchema: ResponseSchema(name: "x", schema: ["type": "object"])))
        XCTAssertEqual(r.text, #"{"ok":true}"#)
        XCTAssertEqual(r.usage.inputTokens, 2000, "cache reads and writes count toward the plan")
        XCTAssertEqual(r.usage.outputTokens, 400)
        let a = try args()
        for flag in ["-p", "--safe-mode", "--no-session-persistence", "--strict-mcp-config"] { XCTAssertTrue(a.contains(flag), flag) }
        XCTAssertEqual(a[a.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertEqual(a[a.firstIndex(of: "--tools")! + 1], "", "no built-in tools")
        XCTAssertEqual(a[a.firstIndex(of: "--max-turns")! + 1], "2")
        XCTAssertTrue(a[a.firstIndex(of: "--system-prompt")! + 1].hasPrefix("Rules."), "replaces Claude Code's own instructions")
        XCTAssertFalse(a.contains("The slides…"), "material goes through stdin, not the command line")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8), "The slides…")
    }

    func testTheActivityLogSeesEachRequestAndClaudeCodesCommand() async throws {
        let started = LockedBox<[(Int32, [String])]>([])
        let events = LockedBox<[String]>([])
        let cli = ClaudeCodeProvider(cli: try fakeCLI(), workingDirectory: dir) { pid, args in started.value.append((pid, args)) }
        let p = ObservedProvider(cli) { e in
            switch e {
            case .request(let r): events.value.append("request \(r.model)")
            case .reply(let r, _): events.value.append("reply \(r.usage.outputTokens)")
            case .failed(let m, _): events.value.append("failed \(m)")
            }
        }
        _ = try await p.send(ChatRequest(model: "sonnet", messages: [.user("hi")]))
        XCTAssertEqual(events.value, ["request sonnet", "reply 400"])
        XCTAssertEqual(started.value.count, 1)
        XCTAssertGreaterThan(started.value[0].0, 0, "the process to watch")
        XCTAssertTrue(started.value[0].1.contains("-p"), "the exact command line")
    }

    func testDropsAFlagAnOlderCLIRejects() async throws {
        let p = ClaudeCodeProvider(cli: try fakeCLI(reject: "--safe-mode"), workingDirectory: dir)
        let r = try await p.send(ChatRequest(model: "haiku", messages: [.user("hi")]))
        XCTAssertEqual(r.text, #"{"ok":true}"#)
        let a = try args()
        XCTAssertFalse(a.contains("--safe-mode"))
        XCTAssertFalse(a.contains("--effort"), "Haiku has no effort setting")
    }

    func testLargeInputToACLIThatExitsEarlyDoesNotCrash() async throws {
        let script = dir.appendingPathComponent("early.sh")
        try "#!/bin/sh\necho 'error: unknown option' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let out = try await CLIRunner.run(script, arguments: [], directory: dir, environment: ProcessInfo.processInfo.environment, timeout: 20,
                                          input: Data(repeating: 65, count: 1_000_000))
        XCTAssertEqual(out.status, 1)
    }

    func testRecognizesWhichOptionalFlagFailed() {
        let flags = CLIRunner.baseFlags(model: "sonnet")
        XCTAssertEqual(CLIRunner.rejectedFlag("error: unknown option '--safe-mode'", in: flags).map { flags[$0].name }, "--safe-mode")
        XCTAssertEqual(CLIRunner.rejectedFlag("API Error: effort level low is not supported by this model", in: flags).map { flags[$0].name }, "--effort")
        XCTAssertNil(CLIRunner.rejectedFlag("error: unknown option '--model'", in: flags), "required flags are never dropped")
        XCTAssertNil(CLIRunner.rejectedFlag("Network unreachable", in: flags))
    }

    func testPlanLimitIsReportedPlainly() async throws {
        let cli = try fakeCLI(reply: #"{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1790000000"}"#)
        do {
            _ = try await ClaudeCodeProvider(cli: cli, workingDirectory: dir).send(ChatRequest(model: "sonnet", messages: [.user("hi")]))
            XCTFail("should throw")
        } catch let e as AIError {
            if case .quotaExhausted = e {} else { XCTFail("\(e)") }
        }
    }

    func testStepLimitIsReportedPlainly() async throws {
        let cli = try fakeCLI(reply: #"{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":2}"#)
        do {
            _ = try await ClaudeCodeProvider(cli: cli, workingDirectory: dir).send(ChatRequest(model: "sonnet", messages: [.user("hi")]))
            XCTFail("should throw")
        } catch let e as AIError {
            if case .budgetExceeded = e {} else { XCTFail("\(e)") }
        }
    }

    func testCourseBuilderLeavesEffortToClaudeCode() async throws {
        _ = try await ClaudeCodeProvider(cli: try fakeCLI(), workingDirectory: dir).send(ChatRequest(model: "sonnet", messages: [.user("hi")]))
        XCTAssertEqual(try args()[try args().firstIndex(of: "--effort")! + 1], "low", "reading files")
        _ = try await ClaudeCodeProvider(cli: try fakeCLI(), workingDirectory: dir, effort: nil).send(ChatRequest(model: "sonnet", messages: [.user("hi")]))
        XCTAssertFalse(try args().contains("--effort"), "building a course")
    }

    func testMeterTreatsThePlanAsUnpaidButCapped() throws {
        let (store, _) = try notesStore()
        AISettings(store: store).monthlyCapUSD = 0
        let meter = StoreUsageMeter(store: store)
        XCTAssertNoThrow(try meter.check(provider: ClaudeCodeProvider.descriptor, model: ClaudeCodeProvider.descriptor.model("sonnet")),
                         "a plan isn't money, so the spending cap doesn't block it")
    }
}

final class DiagramBlockTests: XCTestCase {
    func testChatRepliesSplitAroundDiagrams() {
        let reply = """
        Here is the market:
        ```diagram
        {"kind":"flow","steps":["Price rises","Quantity demanded falls"]}
        ```
        Notice the direction.
        """
        let parts = DiagramBlocks.split(reply)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.first, .text("Here is the market:"))
        if case .diagram(let d) = parts[1] { XCTAssertEqual(d.steps.count, 2) } else { XCTFail() }
        XCTAssertEqual(parts.last, .text("Notice the direction."))
        XCTAssertEqual(DiagramBlocks.split("Plain answer."), [.text("Plain answer.")])
        XCTAssertEqual(DiagramBlocks.split("Drawing:\n```diagram\n{\"kind\":"), [.text("Drawing:"), .pending], "still streaming")
        if case .text(let t) = DiagramBlocks.split("```diagram\nnot json\n```")[0] { XCTAssertTrue(t.contains("not json")) } else { XCTFail() }
    }
}

/// A box from the layout, enough to ask whether a straight segment passes through it.
private struct CGRectLike {
    var o: DPoint, w: Double, h: Double
    func crosses(_ a: DPoint, _ b: DPoint) -> Bool {
        // The path is made of horizontal and vertical segments.
        if a.x == b.x { return a.x > o.x && a.x < o.x + w && max(a.y, b.y) > o.y && min(a.y, b.y) < o.y + h }
        return a.y > o.y && a.y < o.y + h && max(a.x, b.x) > o.x && min(a.x, b.x) < o.x + w
    }
}
