import Foundation

/// What a model can do. Live listings (OpenRouter's /models) fill these precisely; for other providers they're
/// conservative guesses and the user can still pick any model.
public struct ModelInfo: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var contextTokens: Int
    public var tools: Bool
    public var jsonSchema: Bool
    public var vision: Bool
    public var free: Bool
    /// USD per million tokens; nil when unknown.
    public var priceInPerM: Double?
    public var priceOutPerM: Double?

    public init(id: String, name: String? = nil, contextTokens: Int = 32_000, tools: Bool = true, jsonSchema: Bool = false, vision: Bool = false,
                free: Bool = false, priceInPerM: Double? = nil, priceOutPerM: Double? = nil) {
        self.id = id; self.name = name ?? id; self.contextTokens = contextTokens; self.tools = tools; self.jsonSchema = jsonSchema
        self.vision = vision; self.free = free; self.priceInPerM = priceInPerM; self.priceOutPerM = priceOutPerM
    }

    public func cost(_ u: Usage) -> Double? {
        if free { return 0 }
        guard let i = priceInPerM, let o = priceOutPerM else { return nil }
        return (Double(u.inputTokens) * i + Double(u.outputTokens) * o) / 1_000_000
    }
}

/// How a provider treats what it's sent. Shown as a plain label before the student agrees to use it.
public enum DataUse: String, Sendable {
    /// Never leaves the device.
    case onDevice
    /// Apple Private Cloud Compute: processed, not stored, not used for training.
    case privateCloud
    /// The provider's terms say API data isn't used for training.
    case noTraining
    /// Free tier may log or train on prompts; paid use doesn't.
    case freeTierMayTrain
    /// Depends on the model or route the user picks (OpenRouter).
    case varies

    public var label: String {
        switch self {
        case .onDevice: return "Stays on this device"
        case .privateCloud: return "Apple Private Cloud Compute: not stored, not used for training"
        case .noTraining: return "Not used for training"
        case .freeTierMayTrain: return "Free tier may log your material or use it for training"
        case .varies: return "Depends on the model: free models may log or train on your material"
        }
    }

    public var needsTrainingConsent: Bool { self == .freeTierMayTrain || self == .varies }
}

public enum Edition: String, CaseIterable, Sendable {
    /// Mac App Store (sandboxed): Apple's cloud model, no CLIs, no editing other apps' files.
    case macAppStore
    /// Direct download for macOS (Developer ID): everything except Apple's cloud model.
    case macDirect
    case iOS
    /// The minimal Windows/Linux build.
    case crossPlatform

    public static var current: Edition {
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        // Mac App Store copies carry a receipt; STUDY_EDITION lets development builds act as either edition.
        if let forced = ProcessInfo.processInfo.environment["STUDY_EDITION"] { return forced == "appstore" ? .macAppStore : .macDirect }
        let receipt = Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receipt.path) ? .macAppStore : .macDirect
        #else
        return .crossPlatform
        #endif
    }

    public var isSandboxed: Bool { self == .macAppStore || self == .iOS }
}

public struct ProviderDescriptor: Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case openAICompatible(baseURL: String)
        case anthropic
        case appleOnDevice
        case applePCC
    }

    public enum Auth: Sendable, Equatable { case none, apiKey, apiKeyOrSignIn }

    public var id: String
    public var name: String
    public var kind: Kind
    public var auth: Auth
    public var dataUse: DataUse
    /// Something here is free: a free tier, free models, or the whole thing.
    public var hasFreeOption: Bool
    public var runsLocally: Bool
    public var keyURL: String?
    public var blurb: String
    /// Regions (ISO country codes) where the free tier must not be used. Gemini's free tier can't serve the EEA, UK or Switzerland.
    public var freeTierBlockedRegions: Set<String>
    public var editions: Set<Edition>
    public var models: [ModelInfo]
    /// Used when nothing better is known; live listings can override it.
    public var suggestedModel: String?

    public init(id: String, name: String, kind: Kind, auth: Auth, dataUse: DataUse, hasFreeOption: Bool, runsLocally: Bool = false, keyURL: String? = nil,
                blurb: String, freeTierBlockedRegions: Set<String> = [], editions: Set<Edition> = Set(Edition.allCases), models: [ModelInfo] = [], suggestedModel: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.auth = auth; self.dataUse = dataUse; self.hasFreeOption = hasFreeOption
        self.runsLocally = runsLocally; self.keyURL = keyURL; self.blurb = blurb; self.freeTierBlockedRegions = freeTierBlockedRegions
        self.editions = editions; self.models = models; self.suggestedModel = suggestedModel
    }

    public var baseURL: String? { if case .openAICompatible(let u) = kind { return u }; return nil }
    public var isApple: Bool { kind == .appleOnDevice || kind == .applePCC }
    public var needsKey: Bool { auth != .none }

    public func model(_ id: String) -> ModelInfo? { models.first { $0.id == id } }
}

/// The providers the app knows. Model ids here are stable aliases where the provider offers them; everything else
/// comes from the provider's live model list.
public enum Catalog {
    /// EEA + UK + Switzerland.
    public static let europeanRegions: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL",
        "PL", "PT", "RO", "SK", "SI", "ES", "SE", "IS", "LI", "NO", "GB", "CH",
    ]

    public static let appleOnDevice = ProviderDescriptor(
        id: "apple.ondevice", name: "Apple Intelligence (on device)", kind: .appleOnDevice, auth: .none, dataUse: .onDevice,
        hasFreeOption: true, runsLocally: true,
        blurb: "Free and private, works offline. Good for short tasks; long lectures are split into parts.",
        editions: [.macAppStore, .macDirect, .iOS],
        models: [ModelInfo(id: "system", name: "Apple on-device model", contextTokens: 8_192, tools: true, jsonSchema: true, vision: true, free: true)],
        suggestedModel: "system")

    public static let applePCC = ProviderDescriptor(
        id: "apple.pcc", name: "Apple Private Cloud Compute", kind: .applePCC, auth: .none, dataUse: .privateCloud,
        hasFreeOption: true,
        blurb: "Free, with no account or key. A larger Apple model that isn't stored or used for training. Daily limit; higher with iCloud+.",
        editions: [.macAppStore, .iOS],
        models: [ModelInfo(id: "pcc", name: "Apple cloud model", contextTokens: 32_000, tools: true, jsonSchema: true, vision: true, free: true)],
        suggestedModel: "pcc")

    public static let openRouter = ProviderDescriptor(
        id: "openrouter", name: "OpenRouter", kind: .openAICompatible(baseURL: "https://openrouter.ai/api/v1"), auth: .apiKeyOrSignIn,
        dataUse: .varies, hasFreeOption: true, keyURL: "https://openrouter.ai/settings/keys",
        blurb: "One sign-in for hundreds of models, including free ones (about 50 requests a day free, 1,000 after a one-time $10 top-up).")

    public static let groq = ProviderDescriptor(
        id: "groq", name: "Groq", kind: .openAICompatible(baseURL: "https://api.groq.com/openai/v1"), auth: .apiKey,
        dataUse: .noTraining, hasFreeOption: true, keyURL: "https://console.groq.com/keys",
        blurb: "Very fast open models with a free tier (rate-limited).",
        models: [ModelInfo(id: "openai/gpt-oss-120b", name: "GPT-OSS 120B", contextTokens: 131_072, tools: true, jsonSchema: true, priceInPerM: 0.15, priceOutPerM: 0.6),
                 ModelInfo(id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B", contextTokens: 131_072, tools: true, priceInPerM: 0.59, priceOutPerM: 0.79)],
        suggestedModel: "openai/gpt-oss-120b")

    public static let gemini = ProviderDescriptor(
        id: "gemini", name: "Google Gemini", kind: .openAICompatible(baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"), auth: .apiKey,
        dataUse: .freeTierMayTrain, hasFreeOption: true, keyURL: "https://aistudio.google.com/apikey",
        blurb: "Gemini Flash models. The free tier isn't allowed in the EU, UK or Switzerland; there you need a paid key.",
        freeTierBlockedRegions: europeanRegions,
        models: [ModelInfo(id: "gemini-flash-latest", name: "Gemini Flash", contextTokens: 1_000_000, tools: true, jsonSchema: true, vision: true),
                 ModelInfo(id: "gemini-flash-lite-latest", name: "Gemini Flash-Lite", contextTokens: 1_000_000, tools: true, jsonSchema: true, vision: true)],
        suggestedModel: "gemini-flash-latest")

    public static let mistral = ProviderDescriptor(
        id: "mistral", name: "Mistral", kind: .openAICompatible(baseURL: "https://api.mistral.ai/v1"), auth: .apiKey,
        dataUse: .freeTierMayTrain, hasFreeOption: true, keyURL: "https://console.mistral.ai/api-keys",
        blurb: "European models with a free Experiment plan (it may use your data for training).",
        models: [ModelInfo(id: "mistral-small-latest", name: "Mistral Small", contextTokens: 128_000, tools: true, jsonSchema: true, vision: true),
                 ModelInfo(id: "mistral-medium-latest", name: "Mistral Medium", contextTokens: 128_000, tools: true, jsonSchema: true, vision: true)],
        suggestedModel: "mistral-small-latest")

    public static let ollamaCloud = ProviderDescriptor(
        id: "ollama.cloud", name: "Ollama Cloud", kind: .openAICompatible(baseURL: "https://ollama.com/v1"), auth: .apiKey,
        dataUse: .noTraining, hasFreeOption: true, keyURL: "https://ollama.com/settings/keys",
        blurb: "Large open models (Kimi, GLM, GPT-OSS) hosted by Ollama, with a free tier.")

    public static let ollama = ProviderDescriptor(
        id: "ollama", name: "Ollama (on this computer)", kind: .openAICompatible(baseURL: "http://localhost:11434/v1"), auth: .none,
        dataUse: .onDevice, hasFreeOption: true, runsLocally: true,
        blurb: "Free and private. Runs open models on your own computer (16 GB of memory or more recommended).",
        editions: [.macAppStore, .macDirect, .crossPlatform])

    public static let lmStudio = ProviderDescriptor(
        id: "lmstudio", name: "LM Studio (on this computer)", kind: .openAICompatible(baseURL: "http://localhost:1234/v1"), auth: .none,
        dataUse: .onDevice, hasFreeOption: true, runsLocally: true,
        blurb: "Free and private. Start LM Studio's local server and load a model with tool support.",
        editions: [.macAppStore, .macDirect, .crossPlatform])

    public static let anthropic = ProviderDescriptor(
        id: "anthropic", name: "Anthropic (Claude API)", kind: .anthropic, auth: .apiKey, dataUse: .noTraining,
        hasFreeOption: false, keyURL: "https://platform.claude.com/settings/keys",
        blurb: "Claude with your own API key, billed per use. For your Claude Pro or Max plan, use Claude Code instead.",
        models: [ModelInfo(id: "claude-opus-5-5", name: "Claude Opus 5.5", contextTokens: 1_000_000, tools: true, jsonSchema: true, vision: true, priceInPerM: 4, priceOutPerM: 20),
                 ModelInfo(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", contextTokens: 1_000_000, tools: true, jsonSchema: true, vision: true, priceInPerM: 2, priceOutPerM: 10),
                 ModelInfo(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", contextTokens: 200_000, tools: true, jsonSchema: true, vision: true, priceInPerM: 1, priceOutPerM: 5)],
        suggestedModel: "claude-opus-5-5")

    public static let openAI = ProviderDescriptor(
        id: "openai", name: "OpenAI API", kind: .openAICompatible(baseURL: "https://api.openai.com/v1"), auth: .apiKey, dataUse: .noTraining,
        hasFreeOption: false, keyURL: "https://platform.openai.com/api-keys",
        blurb: "GPT models with your own API key, billed per use. (A ChatGPT subscription doesn't include API use.)",
        suggestedModel: "gpt-5-mini")

    public static let deepSeek = ProviderDescriptor(
        id: "deepseek", name: "DeepSeek", kind: .openAICompatible(baseURL: "https://api.deepseek.com/v1"), auth: .apiKey, dataUse: .freeTierMayTrain,
        hasFreeOption: false, keyURL: "https://platform.deepseek.com/api_keys",
        blurb: "Very cheap capable models. DeepSeek's terms allow using your data to improve its models.",
        models: [ModelInfo(id: "deepseek-chat", name: "DeepSeek Chat", contextTokens: 128_000, tools: true)],
        suggestedModel: "deepseek-chat")

    public static let all: [ProviderDescriptor] = [appleOnDevice, applePCC, openRouter, groq, gemini, mistral, ollamaCloud, ollama, lmStudio, anthropic, openAI, deepSeek]

    public static func provider(_ id: String) -> ProviderDescriptor? { all.first { $0.id == id } }

    public static func available(in edition: Edition) -> [ProviderDescriptor] { all.filter { $0.editions.contains(edition) } }

    /// The free model to use on OpenRouter when the student hasn't picked one: tool support and the largest context.
    public static func bestFreeModel(_ models: [ModelInfo], needsTools: Bool = true) -> ModelInfo? {
        models.filter { $0.free && (!needsTools || $0.tools) }
            .sorted { ($0.jsonSchema ? 1 : 0, $0.contextTokens) > ($1.jsonSchema ? 1 : 0, $1.contextTokens) }
            .first
    }
}
