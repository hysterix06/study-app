import Foundation

// One request/response shape for every engine: cloud APIs, Apple's models and (through the job runner) CLIs.

public enum ChatRole: String, Sendable { case system, user, assistant, tool }

public enum ContentPart: Equatable, Sendable {
    case text(String)
    case image(Data, mimeType: String)
}

public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public init(id: String, name: String, arguments: JSONValue) { self.id = id; self.name = name; self.arguments = arguments }
}

public struct ChatMessage: Equatable, Sendable {
    public var role: ChatRole
    public var parts: [ContentPart]
    public var toolCalls: [ToolCall]
    /// For `.tool` messages: which call this answers.
    public var toolCallId: String?
    public var isError: Bool
    /// The provider's own encoding of an assistant turn, replayed unchanged on the next request. Anthropic needs this:
    /// thinking blocks must come back byte-for-byte or later turns lose them.
    public var providerRaw: JSONValue?

    public init(role: ChatRole, parts: [ContentPart] = [], toolCalls: [ToolCall] = [], toolCallId: String? = nil, isError: Bool = false, providerRaw: JSONValue? = nil) {
        self.role = role; self.parts = parts; self.toolCalls = toolCalls; self.toolCallId = toolCallId; self.isError = isError; self.providerRaw = providerRaw
    }

    public static func system(_ s: String) -> ChatMessage { ChatMessage(role: .system, parts: [.text(s)]) }
    public static func user(_ s: String) -> ChatMessage { ChatMessage(role: .user, parts: [.text(s)]) }
    public static func assistant(_ s: String) -> ChatMessage { ChatMessage(role: .assistant, parts: [.text(s)]) }

    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
    public var hasImages: Bool { parts.contains { if case .image = $0 { return true }; return false } }
}

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public init(name: String, description: String, parameters: JSONValue) { self.name = name; self.description = description; self.parameters = parameters }
}

public struct ResponseSchema: Sendable {
    public var name: String
    public var schema: JSONValue
    public init(name: String, schema: JSONValue) { self.name = name; self.schema = schema }
}

public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    /// Ask for JSON matching this schema. Providers without native support get the schema in the prompt instead.
    public var responseSchema: ResponseSchema?
    public var maxOutputTokens: Int
    public var temperature: Double?

    public init(model: String, messages: [ChatMessage], tools: [ToolSpec] = [], responseSchema: ResponseSchema? = nil, maxOutputTokens: Int = 8000, temperature: Double? = nil) {
        self.model = model; self.messages = messages; self.tools = tools; self.responseSchema = responseSchema
        self.maxOutputTokens = maxOutputTokens; self.temperature = temperature
    }
}

public struct Usage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Reported by the provider (OpenRouter) or computed from catalog prices; nil when unknown.
    public var costUSD: Double?
    public init(inputTokens: Int = 0, outputTokens: Int = 0, costUSD: Double? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.costUSD = costUSD
    }
    public static func + (a: Usage, b: Usage) -> Usage {
        let cost: Double? = (a.costUSD == nil && b.costUSD == nil) ? nil : (a.costUSD ?? 0) + (b.costUSD ?? 0)
        return Usage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens, costUSD: cost)
    }
}

public struct ChatResponse: Sendable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var usage: Usage
    /// "stop", "tool_calls", "length", "refusal"…
    public var finishReason: String?
    public var providerRaw: JSONValue?
    public init(text: String, toolCalls: [ToolCall] = [], usage: Usage = Usage(), finishReason: String? = nil, providerRaw: JSONValue? = nil) {
        self.text = text; self.toolCalls = toolCalls; self.usage = usage; self.finishReason = finishReason; self.providerRaw = providerRaw
    }

    /// The assistant message to append to the conversation.
    public var message: ChatMessage {
        ChatMessage(role: .assistant, parts: text.isEmpty ? [] : [.text(text)], toolCalls: toolCalls, providerRaw: providerRaw)
    }
}

/// Errors every engine maps onto, so the queue can back off, fall back or explain in one place.
public enum AIError: Error, Equatable, LocalizedError, Sendable {
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExhausted(message: String, resetAt: Date?)
    case auth(String)
    case modelGone(String)
    case contextTooLong
    case refused(String)
    case network(String)
    case badResponse(String)
    case unavailable(String)
    case budgetExceeded(String)
    case consentRequired(String)
    case canceled

    public var errorDescription: String? {
        switch self {
        case .rateLimited(let s): return s.map { "Too many requests. Try again in \(Int($0.rounded(.up))) s." } ?? "Too many requests. Try again shortly."
        case .quotaExhausted(let m, let reset):
            guard let reset else { return m }
            let f = RelativeDateTimeFormatter()
            return "\(m) It resets \(f.localizedString(for: reset, relativeTo: Date()))."
        case .auth(let m): return m
        case .modelGone(let m): return "The model \(m) is no longer available. Pick another one in Settings › AI."
        case .contextTooLong: return "This is too long for the chosen model. Pick a model with a larger context, or it will be split into smaller parts."
        case .refused(let m): return m.isEmpty ? "The model declined this request." : m
        case .network(let m): return "Could not reach the AI service: \(m)"
        case .badResponse(let m): return "The AI service sent an unexpected answer: \(m)"
        case .unavailable(let m): return m
        case .budgetExceeded(let m): return m
        case .consentRequired(let m): return m
        case .canceled: return "Canceled."
        }
    }

    /// Worth retrying the same engine after a wait.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .network: return true
        default: return false
        }
    }
}

public protocol LLMProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func send(_ request: ChatRequest) async throws -> ChatResponse
    /// Streams text as it arrives; the default sends once and delivers the whole text.
    func stream(_ request: ChatRequest, onText: @escaping @Sendable (String) -> Void) async throws -> ChatResponse
    /// Models the account can use right now, for the picker. Defaults to the catalog's list.
    func listModels() async throws -> [ModelInfo]
}

public extension LLMProvider {
    func stream(_ request: ChatRequest, onText: @escaping @Sendable (String) -> Void) async throws -> ChatResponse {
        let r = try await send(request)
        if !r.text.isEmpty { onText(r.text) }
        return r
    }

    func listModels() async throws -> [ModelInfo] { descriptor.models }
}

/// A provider that runs tools inside its own generation loop (Apple's Foundation Models does this).
public protocol ToolRunningProvider: LLMProvider {
    func run(_ request: ChatRequest, host: ToolHost, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> ChatResponse
}

/// Text that asks for JSON when a provider can't enforce a schema itself.
public enum SchemaPrompt {
    public static func instruction(_ schema: ResponseSchema) -> String {
        """
        Reply with a single JSON object only (no prose, no code fence) that matches this JSON Schema:
        \(schema.schema.serialized())
        """
    }

    /// Pulls the JSON object out of a reply that may be wrapped in prose or a ```json fence.
    public static func extractJSON(_ text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = try? JSONValue.parse(trimmed) { return v }
        if let fence = trimmed.range(of: "```") {
            var body = trimmed[fence.upperBound...]
            if let nl = body.firstIndex(of: "\n") { body = body[body.index(after: nl)...] }
            if let end = body.range(of: "```") { body = body[..<end.lowerBound] }
            if let v = try? JSONValue.parse(String(body)) { return v }
        }
        if let open = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            let close: Character = trimmed[open] == "{" ? "}" : "]"
            if let end = trimmed.lastIndex(of: close), end > open, let v = try? JSONValue.parse(String(trimmed[open...end])) { return v }
        }
        throw AIError.badResponse("the reply was not valid JSON")
    }
}
