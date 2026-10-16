import XCTest
@testable import StudyCore

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
    let name = "Scripted"
    var replies: [(ChatRequest) throws -> ChatResponse]
    var requests: [ChatRequest] = []
    init(replies: [(ChatRequest) throws -> ChatResponse]) { self.replies = replies }
    func send(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        guard !replies.isEmpty else { return ChatResponse(text: "done") }
        return try replies.removeFirst()(request)
    }
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
            let p = AnthropicProvider(apiKey: "k", transport: t)
            do { _ = try await p.send(ChatRequest(model: "m", messages: [.user("x")])); XCTFail("\(status) should throw") } catch let e as AIError {
                XCTAssertTrue(check(e), "\(status): \(e)")
            } catch { XCTFail("\(error)") }
        }
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
        XCTAssertEqual(r.usage.inputTokens, 100)
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
