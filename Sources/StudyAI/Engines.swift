import Foundation
import StudyCore

/// A provider plus model, stored as "provider|model" ("openrouter|qwen/qwen3:free", "apple.ondevice", "cli.claude").
public struct EngineRef: Hashable, Sendable {
    public var providerId: String
    public var model: String?
    public init(_ providerId: String, model: String? = nil) { self.providerId = providerId; self.model = model }
    public init?(string: String?) {
        guard let s = string, !s.isEmpty else { return nil }
        let parts = s.split(separator: "|", maxSplits: 1).map(String.init)
        providerId = parts[0]; model = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
    }
    public var string: String { model.map { "\(providerId)|\($0)" } ?? providerId }

    public static let claudeCode = EngineRef("cli.claude")
    public var isCLI: Bool { providerId.hasPrefix("cli.") }
    public var descriptor: ProviderDescriptor? { Catalog.provider(providerId) }

    /// "Apple Intelligence (on device)", "OpenRouter · gpt-oss-120b:free", "Claude Code".
    public var displayName: String {
        if providerId == EngineRef.claudeCode.providerId { return "Claude Code (your Claude plan)" }
        guard let d = descriptor else { return providerId }
        guard let m = model, !d.isApple else { return d.name }
        return "\(d.name) · \(d.model(m)?.name ?? m)"
    }
}

/// How well a model suits a task, shown next to the engine picker.
public enum TaskFit: Equatable, Sendable {
    case good
    case basic(String)
    case unsupported(String)

    public var isUsable: Bool { if case .unsupported = self { return false }; return true }
    public var note: String? {
        switch self {
        case .good: return nil
        case .basic(let s), .unsupported(let s): return s
        }
    }

    public static func of(_ task: AITask, model: ModelInfo?, providerId: String) -> TaskFit {
        if providerId == EngineRef.claudeCode.providerId {
            return task.conversational ? .unsupported("Conversations run in the chat panel or your AI app.") : .good
        }
        guard let m = model else { return .basic("Unknown model: it may not support everything this task needs.") }
        let pipeline = task == .process || task == .extractDeadlines
        if !pipeline && !m.tools { return .unsupported("This model can't use tools, which \(task.label.lowercased()) needs.") }
        if task == .reviewNotes && !m.vision { return .basic("This model can't read photos, so it works from the recognized text only.") }
        if pipeline && m.contextTokens < 24_000 { return .basic("Small model: long material is split into parts, and results may be basic.") }
        if !pipeline && m.contextTokens < 24_000 { return .basic("Small model: long conversations are shortened as they go.") }
        return .good
    }
}

/// Where API keys live: the Keychain on Apple platforms. Keys never go in the database, logs or MCP configs.
public protocol SecretStore: Sendable {
    func get(_ account: String) -> String?
    func set(_ value: String, account: String)
    func delete(_ account: String)
    func exists(_ account: String) -> Bool
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func get(_ a: String) -> String? { lock.withLock { values[a] } }
    public func set(_ v: String, account a: String) { lock.withLock { values[a] = v } }
    public func delete(_ a: String) { lock.withLock { _ = values.removeValue(forKey: a) } }
    public func exists(_ a: String) -> Bool { lock.withLock { values[a] != nil } }
}

/// The student's AI choices, stored in the settings table.
public struct AISettings: Sendable {
    public let store: StudyStore
    public init(store: StudyStore) { self.store = store }

    public static func keyAccount(_ providerId: String) -> String { "ai.key.\(providerId)" }

    public var defaultEngine: EngineRef? {
        get { EngineRef(string: store.setting("ai_engine_default")) }
        nonmutating set { store.setSetting("ai_engine_default", newValue?.string) }
    }

    public func engine(for task: AITask) -> EngineRef? { EngineRef(string: store.setting("ai_engine.\(task.rawValue)")) ?? defaultEngine }
    public func override(for task: AITask) -> EngineRef? { EngineRef(string: store.setting("ai_engine.\(task.rawValue)")) }
    public func setOverride(_ e: EngineRef?, for task: AITask) { store.setSetting("ai_engine.\(task.rawValue)", e?.string) }

    /// Paid engines stop for the month at this amount (USD). 0 means no paid use at all.
    public var monthlyCapUSD: Double {
        get { store.doubleSetting("ai_monthly_cap_usd", default: 5) }
        nonmutating set { store.setSetting("ai_monthly_cap_usd", String(newValue)) }
    }

    /// Tokens one job may use before it stops, so a runaway loop can't drain a free quota or a paid key.
    public var perJobTokenCap: Int { store.intSetting("ai_job_token_cap", default: 600_000) }

    /// Region used for free-tier rules (Gemini's free tier isn't allowed in the EEA, UK or Switzerland).
    public var region: String {
        get { store.setting("ai_region") ?? Locale.current.region?.identifier ?? "" }
        nonmutating set { store.setSetting("ai_region", newValue) }
    }

    // MARK: Consent

    /// When the student agreed to send course material to this provider. On-device engines need no consent.
    public func consent(_ providerId: String) -> Date? { store.setting("ai_consent.\(providerId)").flatMap { ISO.parse($0) } }
    public func setConsent(_ providerId: String, _ agreed: Bool) {
        store.setSetting("ai_consent.\(providerId)", agreed ? ISO.instant(Date()) : nil)
        store.audit(agreed ? "ai_consent_given" : "ai_consent_withdrawn", detail: providerId)
    }
    /// Separate agreement for providers that may train on free use. Without it OpenRouter only routes to non-training providers.
    public func trainingAllowed(_ providerId: String) -> Bool { store.boolSetting("ai_training_ok.\(providerId)") }
    public func setTrainingAllowed(_ providerId: String, _ ok: Bool) { store.setBool("ai_training_ok.\(providerId)", ok) }

    public func needsConsent(_ d: ProviderDescriptor) -> Bool { d.dataUse != .onDevice && consent(d.id) == nil }

    /// Free tier blocked here (e.g. Gemini in Switzerland): the provider still works with a paid key.
    public func freeTierBlocked(_ d: ProviderDescriptor) -> Bool { d.freeTierBlockedRegions.contains(region.uppercased()) }

    /// The provider's live model list from the last refresh, so capability checks work offline.
    public func cachedModels(_ providerId: String) -> [ModelInfo] {
        guard let s = store.setting("ai_models.\(providerId)") else { return [] }
        return (try? JSONDecoder().decode([ModelInfo].self, from: Data(s.utf8))) ?? []
    }
    public func setCachedModels(_ providerId: String, _ models: [ModelInfo]) {
        store.setSetting("ai_models.\(providerId)", (try? JSONEncoder().encode(models)).map { String(decoding: $0, as: UTF8.self) })
    }

    /// The catalog entry with the live model list folded in.
    public func descriptor(_ providerId: String) -> ProviderDescriptor? {
        guard var d = Catalog.provider(providerId) else { return nil }
        let live = cachedModels(providerId)
        d.models += live.filter { m in !d.models.contains { $0.id == m.id } }
        return d
    }

    /// Chats older than this many days are removed (0 keeps them).
    public var chatRetentionDays: Int { store.intSetting("ai_chat_retention_days", default: 90) }
}

/// Records every request in the usage ledger and enforces the monthly cap and the per-job token cap.
public final class StoreUsageMeter: UsageMeter, @unchecked Sendable {
    let store: StudyStore
    let settings: AISettings
    let jobId: Int?
    let chatId: Int?
    private var jobTokens = 0
    private let lock = NSLock()

    public init(store: StudyStore, jobId: Int? = nil, chatId: Int? = nil) {
        self.store = store; self.settings = AISettings(store: store); self.jobId = jobId; self.chatId = chatId
    }

    public func check(provider: ProviderDescriptor, model: ModelInfo?) throws {
        if lock.withLock({ jobTokens }) > settings.perJobTokenCap {
            throw AIError.budgetExceeded("Stopped: this task used more than \(settings.perJobTokenCap / 1000)k tokens.")
        }
        let paid = !(model?.free ?? false) && !provider.runsLocally && !provider.isApple && model?.priceInPerM != 0
        guard paid, provider.id != Catalog.openRouter.id || !(model?.id.hasSuffix(":free") ?? false) else { return }
        let cap = settings.monthlyCapUSD
        let spent = store.aiSpendThisMonth()
        if spent >= cap {
            throw AIError.budgetExceeded(String(format: "Paused: paid AI use reached this month's limit of $%.2f. Raise it in Settings › AI › Usage, or switch to a free engine.", cap))
        }
    }

    public func record(provider: ProviderDescriptor, model: String, usage: Usage) {
        lock.withLock { jobTokens += usage.inputTokens + usage.outputTokens }
        store.recordAIUsage(provider: provider.id, model: model, jobId: jobId, chatId: chatId, tokensIn: usage.inputTokens, tokensOut: usage.outputTokens,
                            costUSD: provider.runsLocally || provider.isApple ? 0 : usage.costUSD)
    }
}

/// Builds providers. Apple's providers live behind `#if canImport(FoundationModels)` and register themselves here.
public struct ProviderFactory: Sendable {
    public let secrets: SecretStore
    public let settings: AISettings
    public let transport: HTTPTransport
    public var apple: (@Sendable (ProviderDescriptor) throws -> LLMProvider)?

    public init(secrets: SecretStore, settings: AISettings, transport: HTTPTransport = URLSessionTransport()) {
        self.secrets = secrets; self.settings = settings; self.transport = transport
        #if canImport(FoundationModels)
        self.apple = { d in try AppleProviders.make(d) }
        #endif
    }

    public func hasKey(_ d: ProviderDescriptor) -> Bool { !d.needsKey || secrets.exists(AISettings.keyAccount(d.id)) }

    /// Fails with a plain reason (no key, no consent, wrong edition) rather than at the first request.
    public func make(_ ref: EngineRef, edition: Edition = .current, requireConsent: Bool = true) throws -> LLMProvider {
        guard let d = settings.descriptor(ref.providerId) else { throw AIError.unavailable("Unknown AI engine \(ref.providerId).") }
        guard d.editions.contains(edition) else { throw AIError.unavailable("\(d.name) isn't available in this version of Study Tracker.") }
        if requireConsent && settings.needsConsent(d) {
            throw AIError.consentRequired("Before \(d.name) can read your course material, agree to it in Settings › AI.")
        }
        switch d.kind {
        case .appleOnDevice, .applePCC:
            guard let apple else { throw AIError.unavailable("Apple Intelligence isn't available on this system.") }
            return try apple(d)
        case .anthropic:
            guard let key = secrets.get(AISettings.keyAccount(d.id)), !key.isEmpty else { throw AIError.auth("Add your Anthropic API key in Settings › AI.") }
            return AnthropicProvider(descriptor: d, apiKey: key, transport: transport)
        case .openAICompatible:
            let key = secrets.get(AISettings.keyAccount(d.id))
            if d.needsKey && (key ?? "").isEmpty { throw AIError.auth("Add your \(d.name) key in Settings › AI.") }
            return OpenAICompatibleProvider(descriptor: d, apiKey: key, allowTraining: settings.trainingAllowed(d.id), transport: transport)
        }
    }
}

/// The tools each task needs. Fewer tools means a smaller prompt (Apple's on-device model has only a few thousand
/// tokens) and fewer wrong calls on every engine.
public extension AITask {
    var toolNames: Set<String> {
        switch self {
        case .process: return ["get_material", "get_chunks", "get_slide_images", "get_concepts", "save_concepts", "save_questions", "propose_cards", "save_study_notes", "save_cornell_sheet", "mark_material_processed", "record_session"]
        case .extractDeadlines: return ["get_material", "get_chunks", "propose_assignments"]
        case .examPatterns: return ["get_chunks", "get_slide_images", "get_concepts", "save_note", "save_questions"]
        case .checkDraft: return ["list_assignments", "list_materials", "get_chunks", "save_note"]
        case .reviewNotes: return ["get_handwriting_captures", "get_concepts", "get_study_notes", "get_chunks", "save_note", "record_session"]
        case .quiz: return ["get_questions", "get_review_queue", "record_session"]
        case .recall: return ["get_concepts", "get_chunks", "save_note", "record_session"]
        case .explain: return ["get_concepts", "get_study_notes", "get_chunks", "record_session"]
        case .practice: return ["get_study_notes", "get_chunks", "save_questions", "save_note", "record_session"]
        case .weeklyPlan: return ["get_overview", "list_assignments", "get_schedule", "get_review_queue", "get_outcomes", "propose_study_blocks"]
        }
    }

    /// A free chat reads; it doesn't save.
    static let freeChatTools: Set<String> = ["get_overview", "list_courses", "list_assignments", "get_schedule", "get_grade_summary", "list_materials", "get_study_notes", "get_chunks", "get_concepts"]
}
