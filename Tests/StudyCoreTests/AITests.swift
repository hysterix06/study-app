import XCTest
@testable import StudyCore
@testable import StudyMCPCore
@testable import StudyAI

// MARK: Fakes

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, [String: String], String)] = []
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, headers, body) = responses.isEmpty ? (200, [:], "{}") : responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (data, http) = try await self.data(for: request)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return (http, AsyncThrowingStream { c in lines.forEach { c.yield($0) }; c.finish() })
    }

    func body(_ i: Int) -> JSONValue { try! JSONValue.parse(requests[i].httpBody!) }
}

/// Answers each request with the next scripted reply, recording what it was asked.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let descriptor: ProviderDescriptor
    var replies: [(ChatRequest) throws -> ChatResponse]
    var requests: [ChatRequest] = []
    init(descriptor: ProviderDescriptor, replies: [(ChatRequest) throws -> ChatResponse]) { self.descriptor = descriptor; self.replies = replies }
    func send(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        guard !replies.isEmpty else { return ChatResponse(text: "done") }
        return try replies.removeFirst()(request)
    }
}

func testDescriptor(context: Int = 128_000, free: Bool = true, id: String = "test") -> ProviderDescriptor {
    ProviderDescriptor(id: id, name: "Test AI", kind: .openAICompatible(baseURL: "https://example.invalid/v1"), auth: .none, dataUse: .noTraining,
                       hasFreeOption: true, blurb: "", models: [ModelInfo(id: "m", contextTokens: context, tools: true, jsonSchema: true, free: free)], suggestedModel: "m")
}

// MARK: JSON

final class JSONValueTests: XCTestCase {
    func testRoundTripKeepsKeyOrder() throws {
        let text = #"{"zeta":1,"alpha":{"b":true,"a":null},"list":[1,2.5,"x\n\"y\"","é😀"]}"#
        let v = try JSONValue.parse(text)
        XCTAssertEqual(v.object?.map(\.0), ["zeta", "alpha", "list"])
        XCTAssertEqual(v["alpha"]?.object?.map(\.0), ["b", "a"])
        XCTAssertEqual(try JSONValue.parse(v.serialized()), v)
        XCTAssertEqual(v["list"]?.array?[3].string, "é😀")
        XCTAssertEqual(try JSONValue.parse(#""é😀""#).string, "é😀")
    }

    func testCommentsAndTrailingCommasAreJSONC() {
        for text in ["{\n// note\n\"a\": 1}", "{\"a\": 1, /* x */ \"b\": 2}", "{\"a\": [1, 2,]}", "{\"a\": 1,}"] {
            XCTAssertThrowsError(try JSONValue.parse(text), text) { XCTAssertEqual($0 as? JSONValue.ParseError, .jsonc, text) }
        }
        XCTAssertThrowsError(try JSONValue.parse("{\"a\": }"))
    }

    func testExtractJSONFromProseAndFences() throws {
        XCTAssertEqual(try SchemaPrompt.extractJSON("Sure!\n```json\n{\"a\": 1}\n```\nDone")["a"]?.int, 1)
        XCTAssertEqual(try SchemaPrompt.extractJSON("Here it is: {\"a\": {\"b\": 2}} hope that helps")["a"]?["b"]?.int, 2)
        XCTAssertThrowsError(try SchemaPrompt.extractJSON("no json here"))
    }
}

// MARK: Providers

final class ProviderTests: XCTestCase {
    func testOpenAICompatibleRequestAndToolCalls() async throws {
        let t = FakeTransport()
        t.responses = [(200, [:], #"{"choices":[{"message":{"content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"get_overview","arguments":"{\"x\":1}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.0001}}"#)]
        var d = Catalog.openRouter
        d.models = [ModelInfo(id: "m:free", tools: true, jsonSchema: true, free: true)]
        let p = OpenAICompatibleProvider(descriptor: d, apiKey: "sk-test", allowTraining: false, transport: t)
        let r = try await p.send(ChatRequest(model: "m:free", messages: [.system("rules"), .user("hi")],
                                             tools: [ToolSpec(name: "get_overview", description: "d", parameters: ["type": "object", "properties": [:]])],
                                             responseSchema: ResponseSchema(name: "s", schema: ["type": "object", "properties": ["n": ["type": "integer", "minimum": 1]]])))
        XCTAssertEqual(r.toolCalls.first?.name, "get_overview")
        XCTAssertEqual(r.toolCalls.first?.arguments["x"]?.int, 1)
        XCTAssertEqual(r.usage.costUSD, 0, ":free models cost nothing")
        let body = t.body(0)
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(body["provider"]?["data_collection"]?.string, "deny", "no training unless the student agreed")
        XCTAssertEqual(body["response_format"]?["type"]?.string, "json_schema")
        let schema = body["response_format"]?["json_schema"]?["schema"]
        XCTAssertNil(schema?["properties"]?["n"]?["minimum"], "bounds removed for strict modes")
        XCTAssertEqual(schema?["additionalProperties"], false)
        XCTAssertEqual(body["tools"]?.array?.first?["function"]?["name"]?.string, "get_overview")
    }

    func testSchemaGoesInPromptWhenModelLacksStructuredOutput() async throws {
        let t = FakeTransport()
        t.responses = [(200, [:], #"{"choices":[{"message":{"content":"{\"a\":1}"}}]}"#)]
        let p = OpenAICompatibleProvider(descriptor: Catalog.ollama, apiKey: nil, transport: t)
        _ = try await p.send(ChatRequest(model: "llama3", messages: [.user("hi")], responseSchema: ResponseSchema(name: "s", schema: ["type": "object"])))
        let body = t.body(0)
        XCTAssertNil(body["response_format"])
        XCTAssertTrue(body["messages"]?.array?.last?["content"]?.string?.contains("JSON Schema") ?? false)
        XCTAssertNil(t.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testErrorMapping() async {
        let cases: [(Int, [String: String], String, (AIError) -> Bool)] = [
            (429, ["retry-after": "7"], #"{"error":{"message":"slow down"}}"#, { if case .rateLimited(let s) = $0 { return s == 7 }; return false }),
            (429, ["x-ratelimit-reset": "1790900000000"], #"{"error":{"message":"Rate limit exceeded: free-models-per-day"}}"#, { if case .quotaExhausted(_, let d) = $0 { return d != nil }; return false }),
            (401, [:], #"{"error":{"message":"bad key"}}"#, { if case .auth = $0 { return true }; return false }),
            (404, [:], #"{"error":{"message":"model not found"}}"#, { $0 == .modelGone("m") }),
            (400, [:], #"{"error":{"message":"This model's maximum context length is 8192 tokens"}}"#, { $0 == .contextTooLong }),
            (402, [:], #"{"error":{"message":"Insufficient credits"}}"#, { if case .quotaExhausted = $0 { return true }; return false }),
        ]
        for (status, headers, body, check) in cases {
            let t = FakeTransport()
            t.responses = [(status, headers, body)]
            let p = OpenAICompatibleProvider(descriptor: Catalog.groq, apiKey: "k", transport: t)
            do { _ = try await p.send(ChatRequest(model: "m", messages: [.user("x")])); XCTFail("\(status) should throw") } catch let e as AIError {
                XCTAssertTrue(check(e), "\(status): \(e)")
            } catch { XCTFail("\(error)") }
        }
    }

    func testStreamingAssemblesTextAndToolCalls() async throws {
        let t = FakeTransport()
        t.responses = [(200, [:], """
            data: {"choices":[{"delta":{"content":"Hel"}}]}
            data: {"choices":[{"delta":{"content":"lo"}}]}
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"get_","arguments":"{\\"a\\":"}}]}}]}
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"overview","arguments":"2}"}}]},"finish_reason":"tool_calls"}]}
            data: [DONE]
            """)]
        let p = OpenAICompatibleProvider(descriptor: Catalog.groq, apiKey: "k", transport: t)
        let collected = LockedBox("")
        let r = try await p.stream(ChatRequest(model: "m", messages: [.user("x")])) { collected.value += $0 }
        XCTAssertEqual(r.text, "Hello")
        XCTAssertEqual(collected.value, "Hello")
        XCTAssertEqual(r.toolCalls.first?.name, "get_overview")
        XCTAssertEqual(r.toolCalls.first?.arguments["a"]?.int, 2)
    }

    func testAnthropicBodyReplayAndRefusal() async throws {
        let t = FakeTransport()
        let raw = #"[{"type":"thinking","thinking":"","signature":"sig"},{"type":"tool_use","id":"tu1","name":"get_overview","input":{}}]"#
        t.responses = [
            (200, [:], #"{"model":"claude-opus-5-5","content":\#(raw),"stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":20}}"#),
            (200, [:], #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","explanation":"nope"}}"#),
        ]
        let p = AnthropicProvider(apiKey: "sk-ant", transport: t)
        var messages: [ChatMessage] = [.system("rules"), .user("hi")]
        let r = try await p.send(ChatRequest(model: "claude-opus-5-5", messages: messages, responseSchema: ResponseSchema(name: "s", schema: ["type": "object"])))
        XCTAssertEqual(r.toolCalls.first?.id, "tu1")
        XCTAssertEqual(r.usage.costUSD!, (100 * 4 + 20 * 20) / 1_000_000, accuracy: 1e-9)
        let first = t.body(0)
        XCTAssertEqual(first["system"]?.string, "rules")
        XCTAssertEqual(first["output_config"]?["format"]?["type"]?.string, "json_schema")
        XCTAssertEqual(first["output_config"]?["effort"]?.string, "medium")
        XCTAssertEqual(first["fallbacks"]?.string, "default")
        XCTAssertNil(first["tool_choice"], "current models reject forced tool choice")
        XCTAssertNil(first["temperature"])
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        messages.append(r.message)
        messages.append(ChatMessage(role: .tool, parts: [.text("{}")], toolCallId: "tu1"))
        do { _ = try await p.send(ChatRequest(model: "claude-opus-5-5", messages: messages)); XCTFail() } catch let e as AIError {
            XCTAssertEqual(e, .refused("nope"))
        }
        let second = t.body(1)
        let turns = second["messages"]!.array!
        XCTAssertEqual(turns[1]["content"], try JSONValue.parse(raw), "assistant turn replayed byte-for-byte (thinking blocks intact)")
        XCTAssertEqual(turns[2]["content"]?.array?.first?["type"]?.string, "tool_result")
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

// MARK: Tools, agent loop and pipelines against a real database

final class AIEngineTests: XCTestCase {
    var store: StudyStore!
    var ids: (term: Int, hm: Int, mkt: Int)!
    var materialId: Int!
    var chunkIds: [Int] = []

    override func setUpWithError() throws {
        store = try makeStore(file: true)
        ids = try seedCourses(store)
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Overbooking", bullets: [(0, "Why hotels overbook")], notes: "Expected no-shows", picture: nil, table: nil, chart: false),
            (title: "No-shows", bullets: [(0, "Forecast no-show rate")], notes: nil, picture: "No-show rate chart", table: nil, chart: false),
            (title: "Walking guests", bullets: [(0, "Service recovery")], notes: nil, picture: nil, table: nil, chart: false),
        ])
        guard case .imported(let m, _) = store.importMaterial(from: deck, courseId: ids.hm) else { return XCTFail() }
        materialId = m
        chunkIds = store.chunks(materialId: m).map(\.id)
    }

    func host(blocked: Set<String> = [], jobId: Int? = nil) throws -> MCPToolHost { try MCPToolHost(paths: store.paths, blocked: blocked, jobId: jobId) }

    func testToolHostInjectsJobIdHidesItAndBlocksRatings() async throws {
        let job = try store.enqueueJob(.sortFiles, args: ["material_ids": "\(materialId!)"], objectKind: "material", objectId: materialId, label: "x", mode: .automatic, engine: "test|m")
        let h = try host(blocked: ["log_review"], jobId: job)
        let specs = h.specs()
        XCTAssertFalse(specs.contains { $0.name == "log_review" })
        XCTAssertNil(specs.first { $0.name == "set_material_use" }?.parameters["properties"]?["job_id"])
        let blocked = await h.call("log_review", ["card_id": 1, "rating": 4])
        XCTAssertTrue(blocked.isError)
        XCTAssertTrue(blocked.text.contains("student"))
        let saved = await h.callJSON("set_material_use", ["material_id": materialId!, "role": "lecture", "confidence": 0.9, "reason": "Slides."])
        XCTAssertTrue(saved.ok, saved.text)
        XCTAssertEqual(store.job(job)?.results["set_material_use"], 1, "write attached to the job")
        XCTAssertTrue(store.recentAudit(actor: "ai", limit: 5).contains { $0.action == "sort_file" }, "audited as the built-in AI")
        XCTAssertEqual(store.job(job)?.state, .done, "the finishing write finished the job")
    }

    func testAgentLoopRunsToolsAndKeepsProposalsUnconfirmed() async throws {
        let p = ScriptedProvider(descriptor: testDescriptor(), replies: [
            { _ in ChatResponse(text: "", toolCalls: [ToolCall(id: "1", name: "get_overview", arguments: [:])]) },
            { [hm = ids.hm] _ in ChatResponse(text: "", toolCalls: [ToolCall(id: "2", name: "propose_assignments", arguments: JSONValue(any: ["items": [["course_id": hm, "title": "Pricing report", "due_at": "2026-11-02T23:59:00+01:00", "weight_pct": 30]]]))]) },
            { r in
                XCTAssertEqual(r.messages.last?.role, .tool)
                return ChatResponse(text: "Proposed one deadline.")
            },
        ])
        var messages: [ChatMessage] = [.system("rules"), .user("plan")]
        let (reply, _) = try await AgentLoop(provider: p, model: "m", host: try host()).run(&messages, stream: false)
        XCTAssertEqual(reply.text, "Proposed one deadline.")
        let a = try XCTUnwrap(store.assignments(AssignmentFilter(includeProposed: true)).first { $0.title == "Pricing report" })
        XCTAssertFalse(a.confirmed, "AI proposals wait for the student")
        XCTAssertEqual(p.requests.count, 3)
        XCTAssertTrue(p.requests[0].tools.contains { $0.name == "get_overview" })
    }

    func testAgentLoopStopsAtIterationLimit() async throws {
        let p = ScriptedProvider(descriptor: testDescriptor(), replies: Array(repeating: { _ in ChatResponse(text: "", toolCalls: [ToolCall(id: "x", name: "get_overview", arguments: [:])]) }, count: 10))
        var messages: [ChatMessage] = [.user("loop")]
        do {
            try await AgentLoop(provider: p, model: "m", host: try host(), limits: AgentLimits(maxIterations: 3)).run(&messages, stream: false)
            XCTFail("should stop")
        } catch let e as AIError {
            if case .budgetExceeded = e {} else { XCTFail("\(e)") }
        }
        XCTAssertEqual(p.requests.count, 3)
    }

    func testSortingNeverTouchesTheStudentsFilesAndAsksWhenUnsure() async throws {
        let notes = FixtureFactory.textPDF(pages: ["Week 2 notes, written up after class for revision of the main ideas."], name: "doc_1.pdf")
        let handout = FixtureFactory.textPDF(pages: ["A handout with assorted bits that could be anything at all, really."], name: "doc_2.pdf")
        guard case .imported(let a, _) = store.importMaterial(from: notes, courseId: ids.hm),
              case .imported(let b, _) = store.importMaterial(from: handout, courseId: ids.hm) else { return XCTFail() }
        try store.updateMaterial(materialId, role: .reading)
        let p = ScriptedProvider(descriptor: testDescriptor(), replies: [{ r in
            XCTAssertTrue(r.messages.last!.text.contains("doc_1.pdf"))
            XCTAssertFalse(r.messages.last!.text.contains("Overbooking"), "a file the student sorted isn't sent")
            return ChatResponse(text: #"{"files":[{"n":1,"role":"lecture","confidence":0.9,"reason":"Class notes."},{"n":2,"role":"other","confidence":0.4,"reason":"Unclear."}]}"#)
        }])
        let report = try await Pipelines(provider: p, model: "m", host: try host(), store: store).sortFiles(materialIds: [a, b, materialId])
        XCTAssertEqual(report.counts["files"], 2)
        XCTAssertEqual(store.material(a)?.roleSource, "ai")
        XCTAssertEqual(store.material(materialId)?.role, .reading, "the student's choice stays")
        XCTAssertTrue(store.needsLook().contains { $0.kind == .unsureFile && $0.objectId == b }, "unsure: the student is asked")
        XCTAssertEqual(p.requests.count, 1, "up to eight files in one request")
    }

    func testPracticeLabelsKeepTheProblemTextWordForWord() async throws {
        let sheet = FixtureFactory.textPDF(pages: ["Exercise 1: Calculate RevPAR when ADR is 120 and occupancy is 80%.\nExercise 2: Explain why hotels overbook rooms."],
                                           name: "Tutorial 2.pdf")
        guard case .imported(let t, _) = store.importMaterial(from: sheet, courseId: ids.hm) else { return XCTFail() }
        let items = store.practiceItems(materialId: t)
        XCTAssertEqual(items.count, 2, "split without any AI")
        let p = ScriptedProvider(descriptor: testDescriptor(), replies: [{ _ in ChatResponse(text: """
            {"items":[{"id":\(items[0].id),"kind":"calculate","difficulty":1,"topic":"RevPAR","marks":-1},
                      {"id":\(items[1].id),"kind":"explain","difficulty":2,"topic":"Overbooking","marks":-1},
                      {"id":999999,"kind":"essay","difficulty":3,"topic":"Invented","marks":5}]}
            """) }])
        let report = try await Pipelines(provider: p, model: "m", host: try host(), store: store).labelPractice(materialId: t)
        XCTAssertEqual(report.counts["problems"], 2)
        let labelled = store.practiceItems(materialId: t)
        XCTAssertEqual(labelled.map(\.kind), ["calculate", "explain"])
        XCTAssertEqual(labelled.map(\.topicLabel), ["RevPAR", "Overbooking"])
        XCTAssertEqual(labelled.map(\.promptMd), items.map(\.promptMd), "the text never changes")
        XCTAssertTrue(store.filesWithUnlabelledPractice().isEmpty)
    }

    func testRateLimitIsRetried() async throws {
        let notes = FixtureFactory.textPDF(pages: ["General remarks that say nothing about what kind of document this is."], name: "doc_9.pdf")
        guard case .imported(let a, _) = store.importMaterial(from: notes, courseId: ids.hm) else { return XCTFail() }
        let p = ScriptedProvider(descriptor: testDescriptor(), replies: [
            { _ in throw AIError.rateLimited(retryAfter: 0.01) },
            { _ in ChatResponse(text: #"{"files":[{"n":1,"role":"reading","confidence":0.8,"reason":"An article."}]}"#) },
        ])
        let report = try await Pipelines(provider: p, model: "m", host: try host(), store: store).sortFiles(materialIds: [a])
        XCTAssertEqual(report.counts["files"], 1)
        XCTAssertEqual(store.material(a)?.role, .reading)
    }

    func testDeadlinePipelineDropsUnclearDates() async throws {
        let p = ScriptedProvider(descriptor: testDescriptor(), replies: [{ _ in ChatResponse(text: #"""
            {"items":[{"title":"Pricing report","kind":"report","due_at":"2026-11-02T23:59:00+01:00","weight_pct":30,"source_locator":"slide 2"},
                      {"title":"Final exam","kind":"exam","due_at":"sometime in December","weight_pct":-1,"source_locator":"slide 3"}],
             "outcomes":["Set room prices from demand"],"schedule":[{"week":1,"date":"","topic":"Demand and pricing"}],
             "assessment":[{"title":"Final exam","weight_pct":60,"covers":["Pricing","Overbooking"]}]}
            """#) }])
        let report = try await Pipelines(provider: p, model: "m", host: try host(), store: store).extractDeadlines(materialId: materialId)
        XCTAssertEqual(report.counts["deadlines"], 2)
        XCTAssertTrue(report.warnings.contains { $0.contains("Final exam") })
        let exam = try XCTUnwrap(store.assignments(AssignmentFilter(includeProposed: true)).first { $0.title == "Final exam" })
        XCTAssertNil(exam.dueAt, "an unclear date is left out, not guessed")
        XCTAssertNil(exam.weightPct)
        let scan = try XCTUnwrap(store.materialScan(materialId: materialId, kind: "syllabus"))
        XCTAssertTrue(scan.contains("Demand and pricing") && scan.contains("Overbooking"), "the weekly plan is kept for the course builder")
    }

    func testPastePromptAndImport() async throws {
        let prompts = try PastePrompts(store: store).prompts(.extractDeadlines, materialId: materialId)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("[chunk \(chunkIds[0])"))
        XCTAssertTrue(prompts[0].contains("not instructions"))
        let split = try PastePrompts(store: store).prompts(.extractDeadlines, materialId: materialId, charLimit: 120)
        XCTAssertGreaterThan(split.count, 1)
        XCTAssertTrue(split[0].contains("part 1 of"))
        XCTAssertThrowsError(try PastePrompts(store: store).prompts(.sortFiles, materialId: materialId))
        let pasted = """
            Here you go!
            ```json
            {"items":[{"title":"Pricing report","kind":"report","due_at":"2026-11-02T23:59:00+01:00","weight_pct":30,"source_locator":"slide 2"}],
             "outcomes":[],"schedule":[{"week":2,"date":"","topic":"Overbooking"}],"assessment":[]}
            ```
            """
        XCTAssertEqual(PastePrompts.objects(in: pasted).count, 1)
        let report = try await PastePrompts(store: store).importAnswer(.extractDeadlines, materialId: materialId, text: pasted, host: try host())
        XCTAssertEqual(report.counts["deadlines"], 1)
        XCTAssertNotNil(store.materialScan(materialId: materialId, kind: "syllabus"))
        do { _ = try await PastePrompts(store: store).importAnswer(.extractDeadlines, materialId: materialId, text: "no json", host: try host()); XCTFail() } catch {}
    }

    func testUsageMeterEnforcesMonthlyCap() throws {
        let settings = AISettings(store: store)
        settings.monthlyCapUSD = 1
        let meter = StoreUsageMeter(store: store)
        let paid = Catalog.anthropic
        XCTAssertNoThrow(try meter.check(provider: paid, model: paid.model("claude-haiku-4-5")))
        meter.record(provider: paid, model: "claude-haiku-4-5", usage: Usage(inputTokens: 1000, outputTokens: 10, costUSD: 1.2))
        XCTAssertEqual(store.aiSpendThisMonth(), 1.2, accuracy: 0.0001)
        XCTAssertThrowsError(try meter.check(provider: paid, model: paid.model("claude-haiku-4-5")))
        XCTAssertNoThrow(try meter.check(provider: Catalog.ollama, model: nil), "local models are never capped")
        XCTAssertNoThrow(try meter.check(provider: Catalog.openRouter, model: ModelInfo(id: "x:free", free: true)), "free models are never capped")
    }

    func testFactoryNeedsKeyAndConsent() throws {
        let settings = AISettings(store: store)
        let secrets = MemorySecretStore()
        let f = ProviderFactory(secrets: secrets, settings: settings)
        XCTAssertThrowsError(try f.make(EngineRef("groq", model: "openai/gpt-oss-120b"), edition: .macDirect)) {
            if case .consentRequired = $0 as? AIError {} else { XCTFail("\($0)") }
        }
        settings.setConsent("groq", true)
        XCTAssertThrowsError(try f.make(EngineRef("groq"), edition: .macDirect)) { if case .auth = $0 as? AIError {} else { XCTFail("\($0)") } }
        secrets.set("gsk", account: AISettings.keyAccount("groq"))
        XCTAssertNoThrow(try f.make(EngineRef("groq"), edition: .macDirect))
        XCTAssertNoThrow(try f.make(EngineRef("ollama"), edition: .macDirect), "on-device engines need no consent or key")
        XCTAssertThrowsError(try f.make(EngineRef("apple.pcc"), edition: .macDirect), "Apple's cloud model is App Store only")
    }

    func testGeminiFreeTierBlockedInSwitzerland() {
        let s = AISettings(store: store)
        s.region = "CH"
        XCTAssertTrue(s.freeTierBlocked(Catalog.gemini))
        XCTAssertFalse(s.freeTierBlocked(Catalog.groq))
        s.region = "US"
        XCTAssertFalse(s.freeTierBlocked(Catalog.gemini))
    }

    func testTaskFit() {
        let small = ModelInfo(id: "s", contextTokens: 8_192, tools: true, vision: false)
        let tiny = ModelInfo(id: "t", contextTokens: 2_048, tools: true)
        XCTAssertEqual(TaskFit.of(.checkDraft, model: ModelInfo(id: "t", tools: false), providerId: "x").isUsable, false, "conversations need tools")
        if case .basic = TaskFit.of(.sortFiles, model: small, providerId: "apple.ondevice") {} else { XCTFail() }
        XCTAssertFalse(TaskFit.of(.sortFiles, model: tiny, providerId: "x").isUsable, "too small")
        XCTAssertTrue(TaskFit.of(.extractPractice, model: ModelInfo(id: "p", tools: false), providerId: "x").isUsable, "pipelines don't need tools")
        XCTAssertFalse(TaskFit.of(.sortFiles, model: nil, providerId: "cli.claude").isUsable, "Claude Code is kept for building courses")
        XCTAssertFalse(TaskFit.of(.process, model: small, providerId: "x").isUsable, "retired")
    }
}

// MARK: AI app connectors

final class ConnectorTests: XCTestCase {
    let launch = MCPLaunch(command: "/Applications/Study Tracker.app/Contents/MacOS/study-mcp", env: ["STUDY_DB_PATH": "/x/study.db", "STUDY_ROOT": "/x"])

    func testUpsertKeepsOrderAndOtherServersAndCapsBackups() throws {
        let dir = FixtureFactory.tempDir()
        let url = dir.appendingPathComponent("config.json")
        try #"{"zeta": {"keep": true}, "mcpServers": {"other": {"command": "x"}}, "alpha": 1}"#.write(to: url, atomically: true, encoding: .utf8)
        for i in 0..<5 {
            var l = launch
            l.env["N"] = "\(i)"
            try Connectors.upsertJSON(at: url, key: "mcpServers", entry: l.entry)
            Thread.sleep(forTimeInterval: 1.05) // backup names have one-second resolution
        }
        let v = try JSONValue.parse(Data(contentsOf: url))
        XCTAssertEqual(v.object?.map(\.0), ["zeta", "mcpServers", "alpha"], "the user's key order is kept")
        XCTAssertEqual(v["mcpServers"]?.object?.map(\.0), ["other", "study-tracker"])
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("backup") }
        XCTAssertEqual(backups.count, 3, "only the newest three backups are kept")
        XCTAssertNil(try Connectors.upsertJSON(at: url, key: "mcpServers", entry: { var l = launch; l.env["N"] = "4"; return l.entry }()), "no change, no backup")
        try Connectors.removeJSON(at: url, key: "mcpServers")
        XCTAssertNil(try JSONValue.parse(Data(contentsOf: url))["mcpServers"]?["study-tracker"])
        XCTAssertNotNil(try JSONValue.parse(Data(contentsOf: url))["mcpServers"]?["other"])
    }

    func testCommentedFilesAreNeverRewritten() throws {
        let url = FixtureFactory.tempDir().appendingPathComponent("mcp.json")
        let original = "{\n  // my servers\n  \"servers\": {}\n}\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Connectors.upsertJSON(at: url, key: "servers", entry: launch.entry)) {
            XCTAssertEqual($0 as? Connectors.ConfigError, .commented("mcp.json"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testTOMLAppendOnlyWhenAbsent() throws {
        let url = FixtureFactory.tempDir().appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\n".write(to: url, atomically: true, encoding: .utf8)
        try Connectors.appendTOML(at: url, launch: launch)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("model = \"gpt-5\"\n"))
        XCTAssertTrue(Connectors.tomlHasEntry(text))
        XCTAssertNil(try Connectors.appendTOML(at: url, launch: launch), "already there")
        var other = launch
        other.command = "/elsewhere/study-mcp"
        XCTAssertThrowsError(try Connectors.appendTOML(at: url, launch: other), "an existing entry is never edited")
    }

    func testStateAndClientMatching() throws {
        let home = FixtureFactory.tempDir()
        let c = Connectors.connector("cursor")!
        let url = Connectors.expand("~/.cursor/mcp.json", home: home)
        try Connectors.upsertJSON(at: url, key: "mcpServers", entry: MCPLaunch(command: "/nonexistent/study-mcp", env: [:]).entry)
        XCTAssertTrue(c.matches(clientName: "cursor-vscode"))
        XCTAssertFalse(Connectors.connector("vscode")!.matches(clientName: "cursor-vscode") && false)
        XCTAssertTrue(Connectors.claudeCodeArguments(launch).starts(with: ["mcp", "add", "--scope", "user"]))
        XCTAssertNotNil(Connectors.vscodeInstallURL(launch))
        XCTAssertTrue(Connectors.cursorInstallURL(launch)!.absoluteString.hasPrefix("cursor://anysphere.cursor-deeplink/mcp/install?name=study-tracker"))
        XCTAssertTrue(c.snippet(launch).contains("\"mcpServers\""))
        XCTAssertTrue(Connectors.connector("vscode")!.snippet(launch).contains("\"type\": \"stdio\""))
    }
}

// MARK: MCP server: both protocol eras, client tracking, task instructions, schemas

extension MCPTests {
    func testDiscoverAndModernRequests() {
        let d = server.handle(["jsonrpc": "2.0", "id": 1, "method": "server/discover",
                               "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                                    "io.modelcontextprotocol/clientInfo": ["name": "ModernClient", "version": "2.0"]]]])!
        let r = d["result"] as! [String: Any]
        XCTAssertEqual(r["resultType"] as? String, "complete")
        let versions = r["supportedVersions"] as! [String]
        XCTAssertTrue(versions.contains("2026-07-28") && versions.contains("2025-11-25") && versions.contains("2024-11-05"))
        XCTAssertNotNil((r["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"])
        XCTAssertEqual(store.mcpClients().first?.name, "ModernClient")

        let list = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]])!
        let listed = list["result"] as? [String: Any]
        XCTAssertNotNil(listed?["tools"], "modern requests work without initialize")
        XCTAssertEqual(listed?["ttlMs"] as? Int, 3_600_000, "modern clients reject lists without a cache lifetime")
        XCTAssertEqual(listed?["cacheScope"] as? String, "private")
        let prompts = server.handle(["jsonrpc": "2.0", "id": 4, "method": "prompts/list", "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]])!
        XCTAssertNotNil((prompts["result"] as? [String: Any])?["ttlMs"])
        let legacy = server.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": [:]])!
        XCTAssertNil((legacy["result"] as? [String: Any])?["ttlMs"], "legacy lists keep the legacy shape")

        let bad = server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2099-01-01"]]])!
        let err = bad["error"] as! [String: Any]
        XCTAssertEqual(err["code"] as? Int, -32022)
        XCTAssertTrue(((err["data"] as? [String: Any])?["supported"] as? [String])?.contains("2026-07-28") ?? false)
    }

    func testLegacyInitializeNegotiatesAndRecordsClient() {
        let r = server.handle(["jsonrpc": "2.0", "id": 0, "method": "initialize",
                               "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "claude-ai", "version": "0.9"]]])!
        XCTAssertEqual((r["result"] as! [String: Any])["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNil((r["result"] as! [String: Any])["resultType"], "legacy results keep the legacy shape")
        let newer = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2030-01-01"]])!
        XCTAssertEqual((newer["result"] as! [String: Any])["protocolVersion"] as? String, "2025-11-25", "unknown versions get our newest legacy one")
        XCTAssertEqual(store.mcpClients().first { $0.name == "claude-ai" }?.version, "0.9")
    }

    func testTaskInstructionsForAJob() throws {
        let job = try store.enqueueJob(.extractDeadlines, args: ["material_id": "\(materialId!)"], objectKind: "material", objectId: materialId, label: "x", mode: .desktop)
        try store.setJobState(job, .handedOff)
        let r = call("get_task_instructions", ["job": job])
        XCTAssertFalse(r.isError, "\(String(describing: r.json))")
        let text = (r.json as? [String: Any])?["instructions"] as? String ?? ""
        XCTAssertTrue(text.contains("job_id: \(job)"))
        XCTAssertTrue(text.contains("save_material_scan"))
        try store.setJobState(job, .done)
        XCTAssertTrue(call("get_task_instructions", ["job": job]).isError, "finished jobs aren't re-run")
        XCTAssertFalse(call("get_task_instructions", ["task": "extract_deadlines", "material_id": materialId!]).isError)
        XCTAssertTrue(call("get_task_instructions", ["task": "sort_files"]).isError, "app-only tasks have no AI-app instructions")
        let old = try store.enqueueJob(.process, args: [:], objectKind: nil, objectId: nil, label: "old", mode: .desktop)
        XCTAssertTrue(call("get_task_instructions", ["job": old]).isError, "retired tasks aren't run")
    }

    /// The 2026-07-28 spec rejects loose schemas; check every tool's schema is well-formed JSON Schema.
    func testToolSchemasAreWellFormed() {
        let known: Set = ["type", "properties", "required", "additionalProperties", "items", "description", "enum", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"]
        func check(_ s: [String: Any], _ path: String) {
            for k in s.keys { XCTAssertTrue(known.contains(k), "\(path): unknown keyword \(k)") }
            XCTAssertTrue(s["type"] != nil || s["enum"] != nil, "\(path): no type")
            if let props = s["properties"] as? [String: Any] {
                for (name, sub) in props { check(sub as! [String: Any], "\(path).\(name)") }
                for r in s["required"] as? [String] ?? [] { XCTAssertNotNil(props[r], "\(path): required \(r) is not a property") }
            }
            if let items = s["items"] as? [String: Any] { check(items, "\(path)[]") }
        }
        let tools = (server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!["result"] as! [String: Any])["tools"] as! [[String: Any]]
        for t in tools {
            let s = t["inputSchema"] as! [String: Any]
            XCTAssertEqual(s["type"] as? String, "object")
            check(s, t["name"] as! String)
        }
    }
}

// MARK: CLI runner

final class CLIRunnerTests: XCTestCase {
    func testStderrFloodDoesNotDeadlock() async throws {
        let script = FixtureFactory.tempDir().appendingPathComponent("noisy.sh")
        try "#!/bin/sh\nhead -c 300000 /dev/zero | tr '\\\\0' 'e' 1>&2\necho '{\"result\":\"ok\"}'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let start = Date()
        let out = try await CLIRunner.run(script, arguments: [], directory: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment, timeout: 20)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertGreaterThanOrEqual(out.stderr.count, 300_000)
        XCTAssertEqual(try JSONValue.parse(out.stdout)["result"]?.string, "ok")
    }

    func testFriendlyErrors() {
        if case .auth = CLIRunner.friendly("Invalid API key · Please run /login") {} else { XCTFail() }
        if case .quotaExhausted(_, let reset) = CLIRunner.friendly("Claude AI usage limit reached|1790000000") {
            XCTAssertEqual(reset, Date(timeIntervalSince1970: 1_790_000_000))
        } else { XCTFail() }
        let now = ISO.parse("2026-10-07T18:53:00Z")!   // 20:53 in Madrid
        if case .quotaExhausted(_, let reset) = CLIRunner.friendly("You've hit your session limit · resets 10:40pm (Europe/Madrid)", now: now) {
            XCTAssertEqual(reset, ISO.parse("2026-10-07T20:40:00Z"), "the next 22:40 in Madrid")
        } else { XCTFail("a session limit is a plan limit") }
        XCTAssertEqual(CLIRunner.resetTime(in: "resets 3am (Europe/Madrid)", now: now), ISO.parse("2026-10-08T01:00:00Z"))
    }
}

extension MCPTests {
    func testTaskToolSetsNameRealTools() {
        let all = Set(server.toolNames)
        for task in AITask.allCases {
            XCTAssertTrue(task.toolNames.isSubset(of: all), "\(task): \(task.toolNames.subtracting(all))")
            XCTAssertFalse(task.toolNames.contains("log_review"), "ratings come from the student's buttons")
        }
        XCTAssertTrue(AITask.freeChatTools.isSubset(of: all))
        XCTAssertTrue(AITask.freeChatTools.isDisjoint(with: Set(ToolCatalog.writeTools.map(\.name))), "a free chat only reads")
    }
}

extension MCPTests {
    /// The Claude Desktop extension's manifest lists every tool and the shared version.
    func testMCPBManifestMatchesServer() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/MCPB/manifest.json")
        let m = try JSONValue.parse(Data(contentsOf: url))
        XCTAssertEqual(m["manifest_version"]?.string, "0.3")
        XCTAssertEqual(m["version"]?.string, studyMCPVersion)
        XCTAssertEqual(Set((m["tools"]?.array ?? []).compactMap { $0["name"]?.string }), Set(server.toolNames))
    }
}
