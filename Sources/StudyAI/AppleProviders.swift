#if canImport(FoundationModels)
import Foundation
import FoundationModels
import CoreGraphics
import ImageIO

/// Apple's models: on-device (every Apple edition, free, offline) and Private Cloud Compute (App Store builds only,
/// free with a daily limit). Foundation Models runs tool calls inside its own session, so the agent loop hands this
/// provider the tool host instead of executing calls itself.
public enum AppleProviders {
    /// Whether an Apple engine can run here, with a plain reason when it can't.
    public static func availability(_ d: ProviderDescriptor) -> (available: Bool, reason: String?) {
        switch d.kind {
        case .appleOnDevice:
            guard #available(macOS 26.0, iOS 26.0, *) else { return (false, "Needs macOS 26 or iOS 26 or later.") }
            switch SystemLanguageModel.default.availability {
            case .available: return (true, nil)
            case .unavailable(.deviceNotEligible): return (false, "This device can't run Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled): return (false, "Turn on Apple Intelligence in System Settings to use it.")
            case .unavailable(.modelNotReady): return (false, "Apple Intelligence is still downloading. Try again later.")
            case .unavailable: return (false, "Apple Intelligence isn't available right now.")
            }
        case .applePCC:
            guard #available(macOS 27.0, iOS 27.0, *) else { return (false, "Needs macOS 27 or iOS 27 or later.") }
            guard Edition.current == .macAppStore || Edition.current == .iOS else {
                return (false, "Apple's cloud model is only in the App Store version of Study Tracker.")
            }
            switch PrivateCloudComputeLanguageModel().availability {
            case .available: return (true, nil)
            case .unavailable(.deviceNotEligible): return (false, "This device can't use Private Cloud Compute.")
            case .unavailable: return (false, "Private Cloud Compute isn't ready yet. Try again later.")
            }
        default:
            return (false, nil)
        }
    }

    static func make(_ d: ProviderDescriptor) throws -> LLMProvider {
        let a = availability(d)
        guard a.available else { throw AIError.unavailable(a.reason ?? "Apple Intelligence isn't available.") }
        guard #available(macOS 26.0, iOS 26.0, *) else { throw AIError.unavailable("Needs macOS 26 or later.") }
        return AppleProvider(descriptor: withLiveContext(d))
    }

    /// The catalog guesses the context window; the system knows it (it differs between model versions and devices).
    public static func withLiveContext(_ d: ProviderDescriptor) -> ProviderDescriptor {
        var d = d
        var size: Int?
        if d.kind == .appleOnDevice, #available(macOS 26.4, iOS 26.4, *) { size = SystemLanguageModel.default.contextSize }
        if let size, size > 0, !d.models.isEmpty { d.models[0].contextTokens = size }
        return d
    }
}

@available(macOS 26.0, iOS 26.0, *)
struct AppleProvider: ToolRunningProvider {
    let descriptor: ProviderDescriptor

    var isPCC: Bool { descriptor.kind == .applePCC }

    func session(instructions: String, tools: [any Tool]) throws -> LanguageModelSession {
        if isPCC {
            guard #available(macOS 27.0, iOS 27.0, *) else { throw AIError.unavailable("Needs macOS 27.") }
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
        return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
    }

    /// Foundation Models sessions hold their own history, so earlier turns are folded into the prompt as text.
    static func split(_ messages: [ChatMessage]) -> (instructions: String, prompt: String, images: [Data]) {
        let instructions = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
        guard let lastUser = turns.lastIndex(where: { $0.role == .user }) else { return (instructions, turns.map(\.text).joined(separator: "\n"), []) }
        var history: [String] = []
        for m in turns[..<lastUser] {
            switch m.role {
            case .user: history.append("Student: \(m.text)")
            case .assistant: if !m.text.isEmpty { history.append("You: \(m.text)") }
            case .tool: history.append("(Tool result: \(m.text.prefix(1_500)))")
            case .system: break
            }
        }
        let last = turns[lastUser]
        let images = last.parts.compactMap { p -> Data? in if case .image(let d, _) = p { return d }; return nil }
        let prompt = history.isEmpty ? last.text : "Conversation so far:\n" + history.joined(separator: "\n") + "\n\nStudent: " + last.text
        return (instructions, prompt, images)
    }

    func send(_ request: ChatRequest) async throws -> ChatResponse {
        try await run(request, host: nil, onEvent: { _ in })
    }

    func run(_ request: ChatRequest, host: ToolHost, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> ChatResponse {
        try await run(request, host: Optional(host), onEvent: onEvent)
    }

    func run(_ request: ChatRequest, host: ToolHost?, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> ChatResponse {
        let parts = Self.split(request.messages)
        let tools: [any Tool] = try host.map { h in try request.tools.map { try HostTool(spec: $0, host: h, onEvent: onEvent) } } ?? []
        let s = try session(instructions: parts.instructions, tools: tools)
        let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.maxOutputTokens)
        do {
            let text: String
            if let schema = request.responseSchema {
                let gen = try GenerationSchema(root: SchemaBridge.dynamic(schema.schema, name: schema.name), dependencies: [])
                let r = try await s.respond(to: parts.prompt, schema: gen, includeSchemaInPrompt: true, options: options)
                text = r.content.jsonString
            } else if parts.images.isEmpty || !(descriptor.models.first?.vision ?? false) {
                text = try await s.respond(to: parts.prompt, options: options).content
            } else {
                guard #available(macOS 27.0, iOS 27.0, *) else { throw AIError.unavailable("Reading pictures needs macOS 27.") }
                let attachments = parts.images.compactMap(Self.cgImage).map { Attachment($0) }
                text = try await s.respond(options: options) { parts.prompt; attachments }.content
            }
            return ChatResponse(text: text, finishReason: "stop")
        } catch let e as LanguageModelSession.GenerationError {
            throw Self.map(e)
        } catch let e as AIError {
            throw e
        } catch {
            throw Self.mapOther(error)
        }
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func map(_ e: LanguageModelSession.GenerationError) -> AIError {
        switch e {
        case .exceededContextWindowSize: return .contextTooLong
        case .rateLimited, .concurrentRequests: return .rateLimited(retryAfter: 5)
        case .guardrailViolation, .refusal: return .refused("Apple Intelligence declined this request. Try another engine for this material.")
        case .unsupportedLanguageOrLocale: return .unavailable("Apple Intelligence doesn't support this language yet. Pick another engine.")
        case .assetsUnavailable: return .unavailable("Apple Intelligence is still downloading. Try again later.")
        case .decodingFailure: return .badResponse("Apple Intelligence returned an incomplete answer.")
        default: return .badResponse(e.localizedDescription)
        }
    }

    static func mapOther(_ error: Error) -> AIError {
        if #available(macOS 27.0, iOS 27.0, *), let e = error as? PrivateCloudComputeLanguageModel.Error {
            switch e {
            case .quotaLimitReached(let q):
                return .quotaExhausted(message: "Today's free Apple cloud limit is used up\(q.limitIncreaseSuggestion != nil ? " (iCloud+ raises it)" : "").", resetAt: q.resetDate)
            case .networkFailure: return .network("Private Cloud Compute couldn't be reached.")
            case .serviceUnavailable: return .rateLimited(retryAfter: 30)
            @unknown default: return .badResponse("\(e)")
            }
        }
        if error is CancellationError { return .canceled }
        return .badResponse(error.localizedDescription)
    }
}

/// Exposes one Study Tracker tool to a Foundation Models session.
@available(macOS 26.0, iOS 26.0, *)
struct HostTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    let host: ToolHost
    let onEvent: @Sendable (AgentEvent) -> Void

    init(spec: ToolSpec, host: ToolHost, onEvent: @escaping @Sendable (AgentEvent) -> Void) throws {
        name = spec.name
        description = String(spec.description.split(separator: ".").first.map { String($0) + "." } ?? spec.description).prefix(200).description
        // Tool definitions count against the context window, which is small on device: keep them short.
        parameters = try GenerationSchema(root: SchemaBridge.dynamic(SchemaBridge.compact(spec.parameters), name: spec.name), dependencies: [])
        self.host = host; self.onEvent = onEvent
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = (try? JSONValue.parse(arguments.jsonString)) ?? [:]
        onEvent(.toolStarted(name))
        let r = await host.call(name, json)
        onEvent(.toolFinished(name, isError: r.isError))
        let note = r.images.isEmpty ? "" : "\n(\(r.images.count) picture(s) not shown here. Tell the student which slides to look at.)"
        return String(r.text.prefix(12_000)) + note
    }
}

/// JSON Schema → Foundation Models' dynamic schema, for the subset Study Tracker's tools use.
@available(macOS 26.0, iOS 26.0, *)
enum SchemaBridge {
    /// Drops property descriptions (names are usually enough) to save tokens.
    static func compact(_ s: JSONValue) -> JSONValue {
        guard case .object(let pairs) = s else { return s }
        return .object(pairs.compactMap { k, v in
            if k == "properties", case .object(let props) = v {
                return (k, .object(props.map { ($0.0, compact(stripDescription($0.1))) }))
            }
            if k == "items" { return (k, compact(v)) }
            return (k, v)
        })
    }

    static func stripDescription(_ s: JSONValue) -> JSONValue {
        guard case .object(let pairs) = s else { return s }
        return .object(pairs.filter { $0.0 != "description" })
    }

    static func dynamic(_ s: JSONValue, name: String) -> DynamicGenerationSchema {
        let desc = s["description"]?.string
        if let values = s["enum"]?.array?.compactMap(\.string), !values.isEmpty {
            return DynamicGenerationSchema(name: name, description: desc, anyOf: values)
        }
        switch s["type"]?.string {
        case "object":
            let required = Set((s["required"]?.array ?? []).compactMap(\.string))
            let props = (s["properties"]?.object ?? []).map { key, value in
                DynamicGenerationSchema.Property(name: key, description: value["description"]?.string,
                                                 schema: dynamic(value, name: "\(name)_\(key)"), isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: desc, properties: props)
        case "array":
            return DynamicGenerationSchema(arrayOf: dynamic(s["items"] ?? ["type": "string"], name: "\(name)_item"),
                                           minimumElements: s["minItems"]?.int, maximumElements: s["maxItems"]?.int)
        case "integer":
            if let lo = s["minimum"]?.int, let hi = s["maximum"]?.int, lo <= hi { return DynamicGenerationSchema(type: Int.self, guides: [.range(lo...hi)]) }
            return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }
}
#endif
