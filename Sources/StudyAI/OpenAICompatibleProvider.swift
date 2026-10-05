import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One client for every provider that speaks OpenAI's chat-completions dialect: OpenRouter, Groq, Gemini, Mistral,
/// Ollama (local and cloud), LM Studio, OpenAI and DeepSeek.
public struct OpenAICompatibleProvider: LLMProvider {
    public let descriptor: ProviderDescriptor
    let apiKey: String?
    let transport: HTTPTransport
    /// OpenRouter only: route only to providers that don't train on prompts unless the student agreed to it.
    let allowTraining: Bool

    public init(descriptor: ProviderDescriptor, apiKey: String?, allowTraining: Bool = false, transport: HTTPTransport = URLSessionTransport()) {
        self.descriptor = descriptor; self.apiKey = apiKey; self.allowTraining = allowTraining; self.transport = transport
    }

    var isOpenRouter: Bool { descriptor.id == Catalog.openRouter.id }

    // MARK: Requests

    func urlRequest(_ path: String, body: JSONValue?) throws -> URLRequest {
        guard let base = descriptor.baseURL, let url = URL(string: base + path) else { throw AIError.unavailable("No address for \(descriptor.name).") }
        var r = URLRequest(url: url)
        r.timeoutInterval = descriptor.runsLocally ? 600 : 180
        if let apiKey, !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if isOpenRouter {
            r.setValue("Study Tracker", forHTTPHeaderField: "X-Title")
            r.setValue("https://github.com/studytracker/app", forHTTPHeaderField: "HTTP-Referer")
        }
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(body.serialized().utf8)
        }
        return r
    }

    func body(_ req: ChatRequest, stream: Bool) -> JSONValue {
        let info = descriptor.model(req.model)
        let nativeSchema = req.responseSchema != nil && (info?.jsonSchema ?? false)
        var messages = req.messages
        if let schema = req.responseSchema, !nativeSchema { messages.append(.user(SchemaPrompt.instruction(schema))) }
        var b: JSONValue = ["model": .string(req.model), "messages": .array(messages.flatMap(encode))]
        b["max_tokens"] = .number(Double(req.maxOutputTokens))
        if let t = req.temperature { b["temperature"] = .number(t) }
        if !req.tools.isEmpty {
            b["tools"] = .array(req.tools.map { t in
                ["type": "function", "function": ["name": .string(t.name), "description": .string(t.description), "parameters": t.parameters]]
            })
        }
        if let schema = req.responseSchema, nativeSchema {
            b["response_format"] = ["type": "json_schema", "json_schema": ["name": .string(schema.name), "schema": JSONSchemaTools.strictCompatible(schema.schema), "strict": false]]
        }
        if stream {
            b["stream"] = true
            if descriptor.id == Catalog.openAI.id { b["stream_options"] = ["include_usage": true] }
        }
        if isOpenRouter {
            b["usage"] = ["include": true]
            if !allowTraining { b["provider"] = ["data_collection": "deny"] }
        }
        return b
    }

    func encode(_ m: ChatMessage) -> [JSONValue] {
        switch m.role {
        case .system: return [["role": "system", "content": .string(m.text)]]
        case .user: return [["role": "user", "content": content(m.parts)]]
        case .assistant:
            var o: JSONValue = ["role": "assistant", "content": m.text.isEmpty ? .null : .string(m.text)]
            if !m.toolCalls.isEmpty {
                o["tool_calls"] = .array(m.toolCalls.map { c in
                    ["id": .string(c.id), "type": "function", "function": ["name": .string(c.name), "arguments": .string(c.arguments.serialized())]]
                })
            }
            return [o]
        case .tool:
            var out: [JSONValue] = [["role": "tool", "tool_call_id": .string(m.toolCallId ?? ""), "content": .string(m.text.isEmpty ? "(no text)" : m.text)]]
            // Tool messages can't carry pictures in this dialect, so they follow as a user message.
            let images = m.parts.filter { if case .image = $0 { return true }; return false }
            if !images.isEmpty { out.append(["role": "user", "content": content([.text("Pictures returned by the tool:")] + images)]) }
            return out
        }
    }

    func content(_ parts: [ContentPart]) -> JSONValue {
        if parts.count == 1, case .text(let t) = parts[0] { return .string(t) }
        return .array(parts.map { p in
            switch p {
            case .text(let t): return ["type": "text", "text": .string(t)]
            case .image(let d, let mime): return ["type": "image_url", "image_url": ["url": .string("data:\(mime);base64,\(d.base64)")]]
            }
        })
    }

    // MARK: Responses

    public func send(_ request: ChatRequest) async throws -> ChatResponse {
        let r = try urlRequest("/chat/completions", body: body(request, stream: false))
        let (data, http): (Data, HTTPURLResponse)
        do { (data, http) = try await transport.data(for: r) } catch { throw HTTPErrors.mapTransport(error, provider: descriptor) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPErrors.map(status: http.statusCode, headers: http, body: data, provider: descriptor.name, model: request.model)
        }
        guard let v = try? JSONValue.parse(data) else { throw AIError.badResponse("not JSON") }
        // OpenRouter can report an upstream error with HTTP 200.
        if let err = v["error"], !err.isNull {
            let code = err["code"]?.int ?? 400
            throw HTTPErrors.map(status: code, headers: http, body: data, provider: descriptor.name, model: request.model)
        }
        guard let choice = v["choices"]?.array?.first else { throw AIError.badResponse("no choices") }
        let msg = choice["message"] ?? [:]
        let calls = (msg["tool_calls"]?.array ?? []).compactMap(Self.toolCall)
        return ChatResponse(text: msg["content"]?.string ?? "", toolCalls: calls, usage: usage(v["usage"], model: request.model),
                            finishReason: choice["finish_reason"]?.string)
    }

    public func stream(_ request: ChatRequest, onText: @escaping @Sendable (String) -> Void) async throws -> ChatResponse {
        let r = try urlRequest("/chat/completions", body: body(request, stream: true))
        let (http, lines): (HTTPURLResponse, AsyncThrowingStream<String, Error>)
        do { (http, lines) = try await transport.lines(for: r) } catch { throw HTTPErrors.mapTransport(error, provider: descriptor) }
        if !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await l in lines { body += l + "\n" }
            throw HTTPErrors.map(status: http.statusCode, headers: http, body: Data(body.utf8), provider: descriptor.name, model: request.model)
        }
        var text = ""
        var finish: String?
        var usageValue: JSONValue?
        var partial: [Int: (id: String, name: String, args: String)] = [:]
        do {
            for try await raw in lines {
                try Task.checkCancellation()
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let v = try? JSONValue.parse(payload) else { continue }
                if let err = v["error"], !err.isNull {
                    throw HTTPErrors.map(status: err["code"]?.int ?? 500, headers: http, body: Data(payload.utf8), provider: descriptor.name, model: request.model)
                }
                if let u = v["usage"], !u.isNull { usageValue = u }
                guard let choice = v["choices"]?.array?.first else { continue }
                if let f = choice["finish_reason"]?.string { finish = f }
                let delta = choice["delta"] ?? [:]
                if let t = delta["content"]?.string, !t.isEmpty { text += t; onText(t) }
                for c in delta["tool_calls"]?.array ?? [] {
                    let idx = c["index"]?.int ?? 0
                    var p = partial[idx] ?? ("", "", "")
                    if let id = c["id"]?.string { p.id = id }
                    if let n = c["function"]?["name"]?.string { p.name += n }
                    if let a = c["function"]?["arguments"]?.string { p.args += a }
                    partial[idx] = p
                }
            }
        } catch { throw HTTPErrors.mapTransport(error, provider: descriptor) }
        let calls = partial.keys.sorted().compactMap { k -> ToolCall? in
            let p = partial[k]!
            guard !p.name.isEmpty else { return nil }
            return ToolCall(id: p.id.isEmpty ? "call_\(k)" : p.id, name: p.name, arguments: (try? JSONValue.parse(p.args.isEmpty ? "{}" : p.args)) ?? [:])
        }
        return ChatResponse(text: text, toolCalls: calls, usage: usage(usageValue, model: request.model), finishReason: finish)
    }

    static func toolCall(_ c: JSONValue) -> ToolCall? {
        guard let name = c["function"]?["name"]?.string else { return nil }
        let argText = c["function"]?["arguments"]?.string ?? "{}"
        let args = (try? JSONValue.parse(argText.isEmpty ? "{}" : argText)) ?? c["function"]?["arguments"] ?? [:]
        return ToolCall(id: c["id"]?.string ?? UUID().uuidString, name: name, arguments: args)
    }

    func usage(_ u: JSONValue?, model: String) -> Usage {
        var usage = Usage(inputTokens: u?["prompt_tokens"]?.int ?? 0, outputTokens: u?["completion_tokens"]?.int ?? 0)
        if let c = u?["cost"]?.number { usage.costUSD = c } else { usage.costUSD = descriptor.model(model)?.cost(usage) }
        if model.hasSuffix(":free") { usage.costUSD = 0 }
        return usage
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        let r = try urlRequest("/models", body: nil)
        let (data, http): (Data, HTTPURLResponse)
        do { (data, http) = try await transport.data(for: r) } catch { throw HTTPErrors.mapTransport(error, provider: descriptor) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPErrors.map(status: http.statusCode, headers: http, body: data, provider: descriptor.name, model: nil)
        }
        guard let items = (try? JSONValue.parse(data))?["data"]?.array else { return descriptor.models }
        let listed = items.compactMap { m -> ModelInfo? in
            guard var id = m["id"]?.string else { return nil }
            if id.hasPrefix("models/") { id = String(id.dropFirst(7)) } // Gemini
            if let known = descriptor.model(id) { return known }
            if isOpenRouter { return Self.openRouterModel(m, id: id) }
            return ModelInfo(id: id, name: m["name"]?.string ?? id, contextTokens: m["context_length"]?.int ?? m["context_window"]?.int ?? 32_000,
                             tools: true, jsonSchema: descriptor.id == Catalog.openAI.id, vision: false, free: descriptor.runsLocally)
        }
        return listed.isEmpty ? descriptor.models : listed
    }

    static func openRouterModel(_ m: JSONValue, id: String) -> ModelInfo {
        let params = Set((m["supported_parameters"]?.array ?? []).compactMap(\.string))
        let inputs = Set((m["architecture"]?["input_modalities"]?.array ?? []).compactMap(\.string))
        let pin = Double(m["pricing"]?["prompt"]?.string ?? "")
        let pout = Double(m["pricing"]?["completion"]?.string ?? "")
        let free = id.hasSuffix(":free") || (pin == 0 && pout == 0)
        return ModelInfo(id: id, name: m["name"]?.string ?? id, contextTokens: m["context_length"]?.int ?? 32_000,
                         tools: params.contains("tools"), jsonSchema: params.contains("structured_outputs") || params.contains("response_format"),
                         vision: inputs.contains("image"), free: free,
                         priceInPerM: pin.map { $0 * 1_000_000 }, priceOutPerM: pout.map { $0 * 1_000_000 })
    }
}

/// Small JSON Schema adjustments some providers require.
public enum JSONSchemaTools {
    /// Removes keywords strict structured-output modes reject (numeric and length bounds) and closes every object.
    public static func strictCompatible(_ s: JSONValue) -> JSONValue {
        switch s {
        case .object(let pairs):
            let dropped: Set = ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "pattern", "format"]
            var out = pairs.filter { !dropped.contains($0.0) }.map { key, value -> (String, JSONValue) in
                // "properties" maps names to schemas: the names themselves are never keywords to drop.
                if key == "properties", case .object(let props) = value { return (key, .object(props.map { ($0.0, strictCompatible($0.1)) })) }
                return (key, strictCompatible(value))
            }
            if out.contains(where: { $0.0 == "type" && $0.1 == "object" }), !out.contains(where: { $0.0 == "additionalProperties" }) {
                out.append(("additionalProperties", false))
            }
            return .object(out)
        case .array(let a): return .array(a.map(strictCompatible))
        default: return s
        }
    }
}
