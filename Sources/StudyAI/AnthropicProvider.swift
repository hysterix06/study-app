import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude through the Messages API with the student's own API key (raw HTTP: there is no official Swift SDK).
/// Assistant turns are replayed exactly as received so thinking blocks stay valid across a tool loop, and JSON is
/// requested with `output_config.format` because current models reject forced `tool_choice`.
public struct AnthropicProvider: LLMProvider {
    public let descriptor: ProviderDescriptor
    let apiKey: String
    let transport: HTTPTransport
    let baseURL = "https://api.anthropic.com"

    public init(descriptor: ProviderDescriptor = Catalog.anthropic, apiKey: String, transport: HTTPTransport = URLSessionTransport()) {
        self.descriptor = descriptor; self.apiKey = apiKey; self.transport = transport
    }

    /// Models that accept the server-side refusal fallback (`fallbacks: "default"`).
    static let fallbackModels: Set = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    func request(_ path: String, body: JSONValue?, model: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: baseURL + path)!)
        r.timeoutInterval = 600
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let model, Self.fallbackModels.contains(model) { r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            r.httpBody = Data(body.serialized().utf8)
        }
        return r
    }

    func body(_ req: ChatRequest) -> JSONValue {
        let system = req.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        var b: JSONValue = ["model": .string(req.model), "max_tokens": .number(Double(max(req.maxOutputTokens, 4096))),
                            "messages": .array(encodeMessages(req.messages.filter { $0.role != .system }))]
        if !system.isEmpty { b["system"] = .string(system) }
        if !req.tools.isEmpty {
            b["tools"] = .array(req.tools.map { ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters] })
        }
        var output: JSONValue = [:]
        if let schema = req.responseSchema { output["format"] = ["type": "json_schema", "schema": JSONSchemaTools.strictCompatible(schema.schema)] }
        // Opus 5.5 defaults to medium effort; say so explicitly so a default change upstream doesn't change cost.
        if req.model == "claude-opus-5-5" { output["effort"] = "medium" }
        if output.object?.isEmpty == false { b["output_config"] = output }
        if Self.fallbackModels.contains(req.model) { b["fallbacks"] = "default" }
        return b
    }

    func encodeMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        var pendingResults: [JSONValue] = []
        func flush() { if !pendingResults.isEmpty { out.append(["role": "user", "content": .array(pendingResults)]); pendingResults = [] } }
        for m in messages {
            switch m.role {
            case .tool:
                var content: [JSONValue] = []
                if !m.text.isEmpty { content.append(["type": "text", "text": .string(m.text)]) }
                content += m.parts.compactMap { p in if case .image(let d, let mime) = p { return imageBlock(d, mime) }; return nil }
                var r: JSONValue = ["type": "tool_result", "tool_use_id": .string(m.toolCallId ?? ""), "content": .array(content.isEmpty ? [["type": "text", "text": "(no output)"]] : content)]
                if m.isError { r["is_error"] = true }
                pendingResults.append(r)
            case .assistant:
                flush()
                if let raw = m.providerRaw { out.append(["role": "assistant", "content": raw]); continue }
                var blocks: [JSONValue] = []
                if !m.text.isEmpty { blocks.append(["type": "text", "text": .string(m.text)]) }
                blocks += m.toolCalls.map { ["type": "tool_use", "id": .string($0.id), "name": .string($0.name), "input": $0.arguments] }
                out.append(["role": "assistant", "content": .array(blocks)])
            case .user:
                flush()
                out.append(["role": "user", "content": .array(m.parts.map { p in
                    switch p {
                    case .text(let t): return ["type": "text", "text": .string(t)]
                    case .image(let d, let mime): return imageBlock(d, mime)
                    }
                })])
            case .system: break
            }
        }
        flush()
        return out
    }

    func imageBlock(_ d: Data, _ mime: String) -> JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": .string(mime), "data": .string(d.base64)]]
    }

    public func send(_ req: ChatRequest) async throws -> ChatResponse {
        let (data, http): (Data, HTTPURLResponse)
        do { (data, http) = try await transport.data(for: request("/v1/messages", body: body(req), model: req.model)) } catch {
            throw HTTPErrors.mapTransport(error, provider: descriptor)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPErrors.map(status: http.statusCode, headers: http, body: data, provider: descriptor.name, model: req.model)
        }
        guard let v = try? JSONValue.parse(data) else { throw AIError.badResponse("not JSON") }
        return try Self.parse(v, model: req.model, descriptor: descriptor)
    }

    static func parse(_ v: JSONValue, model: String, descriptor: ProviderDescriptor) throws -> ChatResponse {
        let blocks = v["content"]?.array ?? []
        let stop = v["stop_reason"]?.string
        if stop == "refusal" {
            throw AIError.refused(v["stop_details"]?["explanation"]?.string ?? "Claude declined this request.")
        }
        let text = blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
        let calls = blocks.filter { $0["type"]?.string == "tool_use" }.compactMap { b -> ToolCall? in
            guard let id = b["id"]?.string, let name = b["name"]?.string else { return nil }
            return ToolCall(id: id, name: name, arguments: b["input"] ?? [:])
        }
        let u = v["usage"]
        var usage = Usage(inputTokens: (u?["input_tokens"]?.int ?? 0) + (u?["cache_read_input_tokens"]?.int ?? 0) + (u?["cache_creation_input_tokens"]?.int ?? 0),
                          outputTokens: u?["output_tokens"]?.int ?? 0)
        usage.costUSD = descriptor.model(v["model"]?.string ?? model)?.cost(usage) ?? descriptor.model(model)?.cost(usage)
        return ChatResponse(text: text, toolCalls: calls, usage: usage, finishReason: stop == "tool_use" ? "tool_calls" : stop, providerRaw: .array(blocks))
    }

    public func listModels() async throws -> [ModelInfo] {
        let (data, http): (Data, HTTPURLResponse)
        do { (data, http) = try await transport.data(for: request("/v1/models?limit=100", body: nil)) } catch {
            throw HTTPErrors.mapTransport(error, provider: descriptor)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPErrors.map(status: http.statusCode, headers: http, body: data, provider: descriptor.name, model: nil)
        }
        let items = (try? JSONValue.parse(data))?["data"]?.array ?? []
        let listed = items.compactMap { m -> ModelInfo? in
            guard let id = m["id"]?.string else { return nil }
            if let known = descriptor.model(id) { return known }
            return ModelInfo(id: id, name: m["display_name"]?.string ?? id, contextTokens: m["max_input_tokens"]?.int ?? 200_000, tools: true, jsonSchema: true, vision: true)
        }
        return listed.isEmpty ? descriptor.models : listed
    }
}
