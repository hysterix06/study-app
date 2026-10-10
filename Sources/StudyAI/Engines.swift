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
        if task.isRetired { return .unsupported("This task was replaced in the new version.") }
        if providerId == EngineRef.claudeCode.providerId {
            if task.engineLane == .builder { return .good }
            return .unsupported(task.conversational ? "Conversations run in the chat here or in your AI app."
                                                    : "Claude Code is kept for building courses. Everyday work runs on free AI.")
        }
        guard let m = model else { return .basic("Unknown model: it may not support everything this task needs.") }
        if task.usesTools && !m.tools { return .unsupported("This model can't use tools, which \(task.label.lowercased()) needs.") }
        if m.contextTokens < task.minContext { return .unsupported("This model is too small for \(task.label.lowercased()).") }
        if m.contextTokens < 24_000 {
            return .basic(task.usesTools ? "Small model: long conversations are shortened as they go." : "Small model: long files are read in parts.")
        }
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

    /// Everyday AI (sorting and reading files, feedback, the tutor). Nil means automatic: the on-device model first.
    /// Earlier versions kept one engine for everything in `ai_engine_default`, which is honoured until changed.
    public var everyday: EngineRef? {
        get {
            if let v = store.setting("ai_everyday") { return v == "auto" ? nil : EngineRef(string: v) }
            guard let old = store.setting("ai_engine_default"), old != "handoff", let r = EngineRef(string: old), !r.isCLI else { return nil }
            return r
        }
        nonmutating set { store.setSetting("ai_everyday", newValue?.string ?? "auto") }
    }

    /// Course builder: who lays out each course, writes its notebook guide and its lessons.
    public var builder: BuilderChoice {
        get { BuilderChoice(setting: store.setting("ai_builder")) }
        nonmutating set { store.setSetting("ai_builder", newValue.setting) }
    }

    /// The student said yes to a course builder (in setup or Settings), so it builds every course on its own. Until
    /// then free AI builds basic versions, and a course is only built fully when the student asks for that course.
    public var builderChosen: Bool { (store.setting("ai_builder") ?? "basic") != "basic" }

    /// Lets paid engines run everyday work without being picked for it (off by default: everyday work stays free).
    public var allowPaidEveryday: Bool {
        get { store.boolSetting("ai_allow_paid_everyday") }
        nonmutating set { store.setBool("ai_allow_paid_everyday", newValue) }
    }

    /// The model the student picked for a provider, kept per provider so choosing one never changes another setting.
    public func model(forProvider id: String) -> String? {
        if let m = store.setting("ai_model.\(id)") { return m }
        for key in ["ai_everyday", "ai_engine_default"] {
            if let r = EngineRef(string: store.setting(key)), r.providerId == id, let m = r.model { return m }
        }
        return nil
    }
    public func setModel(_ model: String?, forProvider id: String) { store.setSetting("ai_model.\(id)", model) }

    /// OpenRouter's free models allow about 50 requests a day (1,000 after a one-time top-up).
    public var openRouterFreePerDay: Int { store.intSetting("ai_openrouter_free_per_day", default: 50) }

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
    let tokenCap: Int?
    private var jobTokens = 0
    private let lock = NSLock()

    /// `tokenCap` replaces the per-job limit for jobs that are big by nature (writing a unit's notebook guide).
    public init(store: StudyStore, jobId: Int? = nil, chatId: Int? = nil, tokenCap: Int? = nil) {
        self.store = store; self.settings = AISettings(store: store); self.jobId = jobId; self.chatId = chatId; self.tokenCap = tokenCap
    }

    public func check(provider: ProviderDescriptor, model: ModelInfo?) throws {
        let tokenLimit = tokenCap ?? settings.perJobTokenCap
        if lock.withLock({ jobTokens }) > tokenLimit {
            throw AIError.budgetExceeded("Stopped: this task used more than \(tokenLimit / 1000)k tokens.")
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
/// tokens) and fewer wrong calls on every engine. Pipelines call their tools directly, so they list them too.
public extension AITask {
    var toolNames: Set<String> {
        switch self {
        case .sortFiles: return ["set_material_use"]
        case .buildPath: return ["get_course_signals", "get_path", "get_topic", "list_materials", "get_material", "get_chunks", "get_slide_images",
                                 "get_practice", "save_path"]
        case .writeNotebook: return ["get_path", "get_topic", "get_chunks", "get_slide_images", "save_notebook"]
        case .writeLessons: return ["get_path", "get_topic", "get_chunks", "get_slide_images", "get_practice", "save_lessons"]
        case .checkAnswer, .explainFeedback: return []
        case .buildPathBasic: return ["save_path"]
        case .writeNotebookBasic: return ["save_notebook"]
        case .writeLessonsBasic: return ["save_lessons"]
        case .extractDeadlines: return ["get_material", "get_chunks", "propose_assignments", "save_material_scan"]
        case .extractPractice, .extractExam: return ["get_practice", "label_practice_items"]
        case .checkDraft: return ["list_assignments", "list_materials", "get_chunks", "save_note"]
        default: return []
        }
    }

    /// A free chat reads; it doesn't save.
    static let freeChatTools: Set<String> = ["get_overview", "list_courses", "list_assignments", "get_schedule", "get_grade_summary", "list_materials", "get_chunks"]
}
