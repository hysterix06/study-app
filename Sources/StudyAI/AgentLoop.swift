import Foundation

public enum AgentEvent: Sendable {
    case text(String)
    case toolStarted(String)
    case toolFinished(String, isError: Bool)
    case usage(Usage)
}

public struct AgentLimits: Sendable {
    public var maxIterations: Int
    public var maxTotalTokens: Int
    public init(maxIterations: Int = 24, maxTotalTokens: Int = 600_000) { self.maxIterations = maxIterations; self.maxTotalTokens = maxTotalTokens }
}

/// Checks spending before each request and records it after. The app backs this with the usage ledger and budget settings.
public protocol UsageMeter: Sendable {
    func check(provider: ProviderDescriptor, model: ModelInfo?) throws
    func record(provider: ProviderDescriptor, model: String, usage: Usage)
}

/// A tool-calling loop for chats and for tasks that need the model to explore (weekly plan, exam patterns).
/// Background lecture processing uses `Pipelines` instead: fewer requests, so it works on free tiers and small models.
public struct AgentLoop: Sendable {
    public let provider: LLMProvider
    public let model: String
    public let host: ToolHost
    public let limits: AgentLimits
    public let meter: UsageMeter?

    public init(provider: LLMProvider, model: String, host: ToolHost, limits: AgentLimits = AgentLimits(), meter: UsageMeter? = nil) {
        self.provider = provider; self.model = model; self.host = host; self.limits = limits; self.meter = meter
    }

    var info: ModelInfo? { provider.descriptor.model(model) }

    /// Runs until the model answers without calling a tool. `messages` gains every turn, so a chat can continue later.
    @discardableResult
    public func run(_ messages: inout [ChatMessage], stream: Bool = true, onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in }) async throws -> (reply: ChatResponse, usage: Usage) {
        let tools = host.specs()
        var total = Usage()
        if let p = provider as? ToolRunningProvider {
            try meter?.check(provider: provider.descriptor, model: info)
            let request = ChatRequest(model: model, messages: Self.fit(messages, contextTokens: info?.contextTokens ?? 8_000), tools: tools, maxOutputTokens: 2_000)
            let reply = try await p.run(request, host: host, onEvent: onEvent)
            onEvent(.text(reply.text))
            meter?.record(provider: provider.descriptor, model: model, usage: reply.usage)
            messages.append(reply.message)
            return (reply, reply.usage)
        }
        for _ in 0..<limits.maxIterations {
            try Task.checkCancellation()
            try meter?.check(provider: provider.descriptor, model: info)
            let request = ChatRequest(model: model, messages: Self.fit(messages, contextTokens: info?.contextTokens ?? 32_000), tools: tools, maxOutputTokens: 8000)
            let reply = stream
                ? try await provider.stream(request) { onEvent(.text($0)) }
                : try await provider.send(request)
            if !stream, !reply.text.isEmpty { onEvent(.text(reply.text)) }
            total = total + reply.usage
            meter?.record(provider: provider.descriptor, model: model, usage: reply.usage)
            onEvent(.usage(reply.usage))
            messages.append(reply.message)
            if total.inputTokens + total.outputTokens > limits.maxTotalTokens {
                throw AIError.budgetExceeded("Stopped after \(total.inputTokens + total.outputTokens) tokens, the limit for one task.")
            }
            guard !reply.toolCalls.isEmpty else { return (reply, total) }
            for call in reply.toolCalls {
                try Task.checkCancellation()
                onEvent(.toolStarted(call.name))
                let r = await host.call(call.name, call.arguments)
                onEvent(.toolFinished(call.name, isError: r.isError))
                var parts: [ContentPart] = [.text(r.text)]
                if !r.images.isEmpty {
                    if info?.vision ?? false {
                        parts += r.images.map { .image($0.0, mimeType: $0.1) }
                    } else {
                        parts = [.text(r.text + "\n(\(r.images.count) picture(s) not shown: this model can't read pictures. Tell the student which slides to check themselves.)")]
                    }
                }
                messages.append(ChatMessage(role: .tool, parts: parts, toolCallId: call.id, isError: r.isError))
            }
        }
        throw AIError.budgetExceeded("Stopped after \(limits.maxIterations) steps without finishing.")
    }

    /// Keeps the conversation inside the context window: system messages stay, then the newest turns that fit.
    /// Cuts only before a user message so a tool call is never separated from its result.
    static func fit(_ messages: [ChatMessage], contextTokens: Int) -> [ChatMessage] {
        let budget = Int(Double(contextTokens) * 0.75)
        func cost(_ m: ChatMessage) -> Int {
            m.parts.reduce(8) { acc, p in
                switch p {
                case .text(let t): return acc + t.count / 4
                case .image: return acc + 1_000
                }
            } + m.toolCalls.reduce(0) { $0 + $1.arguments.serialized().count / 4 }
        }
        let system = messages.filter { $0.role == .system }
        let rest = messages.filter { $0.role != .system }
        var used = system.reduce(0) { $0 + cost($1) }
        guard used + rest.reduce(0, { $0 + cost($1) }) > budget else { return messages }
        var start = rest.count
        for i in stride(from: rest.count - 1, through: 0, by: -1) {
            used += cost(rest[i])
            if used > budget { break }
            if rest[i].role == .user { start = i }
        }
        if start == rest.count, let lastUser = rest.lastIndex(where: { $0.role == .user }) { start = lastUser }
        let note = ChatMessage.system("(Earlier parts of this conversation were left out to fit the model's memory.)")
        return system + [note] + Array(rest[start...])
    }
}
