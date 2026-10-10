import Foundation
import StudyCore

/// What the student chose for building courses (the path, the notebook guide and lessons).
public enum BuilderChoice: Equatable, Sendable {
    /// Claude Code when it's here, else a strong engine with a key; otherwise free AI builds a basic version.
    case automatic
    case claudeCode
    case engine(EngineRef)
    /// Never a strong engine: free AI builds a basic version.
    case basicOnly

    public init(setting: String?) {
        switch setting {
        case nil, "", "auto": self = .automatic
        case "cli": self = .claudeCode
        case "basic": self = .basicOnly
        case let s?: self = EngineRef(string: s).map(BuilderChoice.engine) ?? .automatic
        }
    }

    public var setting: String? {
        switch self {
        case .automatic: return "auto"
        case .claudeCode: return "cli"
        case .basicOnly: return "basic"
        case .engine(let r): return r.string
        }
    }
}

/// An engine that can run right now (key, consent and availability already checked) and what its model can do.
public struct EngineCandidate: Equatable, Sendable {
    public var ref: EngineRef
    public var free: Bool
    public var contextTokens: Int
    public var tools: Bool
    /// Apple's on-device model.
    public var appleOnDevice: Bool
    /// Apple Private Cloud Compute.
    public var appleCloud: Bool
    /// Runs on this computer without Apple (Ollama, LM Studio).
    public var local: Bool
    /// Strong enough to build a course: a frontier model the student pays for or connected on purpose.
    public var strong: Bool

    public init(ref: EngineRef, free: Bool, contextTokens: Int, tools: Bool = true, appleOnDevice: Bool = false, appleCloud: Bool = false,
                local: Bool = false, strong: Bool = false) {
        self.ref = ref; self.free = free; self.contextTokens = contextTokens; self.tools = tools
        self.appleOnDevice = appleOnDevice; self.appleCloud = appleCloud; self.local = local; self.strong = strong
    }
}

/// Picks the engines a task tries, best first. The job runner works down the list when one fails, so a broken key, a
/// used-up free tier or an engine that went away never stops the work; an empty list means nothing here can run the
/// task (a course-building task then falls back to its basic version).
///
/// The student sees two choices: Everyday AI (sorting and reading files, feedback, the tutor) and Course builder. The
/// rest is automatic: bulk work prefers the on-device model (free, private, no daily limit), work the student reads
/// prefers the best free model, and building a course prefers Claude.
public enum EngineResolver {
    public struct Inputs: Sendable {
        public var ready: [EngineCandidate]
        /// Claude Code is installed and this edition may run it (never in sandboxed builds).
        public var cliAvailable: Bool
        /// The student's Everyday AI, or nil for automatic.
        public var everyday: EngineRef?
        public var builder: BuilderChoice
        /// Paid engines may run everyday work without being picked for it.
        public var allowPaidEveryday: Bool
        /// Providers whose free requests are used up today.
        public var exhausted: Set<String>

        public init(ready: [EngineCandidate], cliAvailable: Bool = false, everyday: EngineRef? = nil, builder: BuilderChoice = .automatic,
                    allowPaidEveryday: Bool = false, exhausted: Set<String> = []) {
            self.ready = ready; self.cliAvailable = cliAvailable; self.everyday = everyday; self.builder = builder
            self.allowPaidEveryday = allowPaidEveryday; self.exhausted = exhausted
        }
    }

    public static func candidates(for task: AITask, _ i: Inputs) -> [EngineRef] {
        guard !task.isRetired else { return [] }
        let fits = i.ready.filter { c in
            c.contextTokens >= task.minContext && (!task.usesTools || c.tools) && !(c.free && i.exhausted.contains(c.ref.providerId))
                && !(task.needsReasoning && c.appleOnDevice)
        }
        var out: [EngineRef] = []
        func add(_ r: EngineRef) { if !out.contains(r) { out.append(r) } }

        switch task.engineLane {
        case .builder:
            switch i.builder {
            case .basicOnly: break
            case .claudeCode: if i.cliAvailable { add(.claudeCode) }
            case .engine(let chosen):
                if chosen.isCLI { if i.cliAvailable { add(.claudeCode) } }
                else if let c = fits.first(where: { $0.ref.providerId == chosen.providerId }) { add(chosen.model == nil ? c.ref : chosen) }
            case .automatic:
                if i.cliAvailable { add(.claudeCode) }
                for c in fits where c.strong { add(c.ref) }
            }
            return out
        case .bulk, .quality:
            // The student's own pick goes first, even a paid one: they chose it.
            if let e = i.everyday, !e.isCLI, let c = fits.first(where: { $0.ref.providerId == e.providerId }) {
                add(e.model == nil ? c.ref : e)
            }
            let freeOnline: (EngineCandidate) -> Bool = { $0.free && !$0.appleOnDevice && !$0.appleCloud && !$0.local }
            let order: [(EngineCandidate) -> Bool] = task.engineLane == .bulk
                ? [{ $0.appleOnDevice }, { $0.appleCloud }, { $0.local }, freeOnline]
                : [{ $0.appleCloud }, freeOnline, { $0.appleOnDevice }, { $0.local }]
            for matches in order { for c in fits where matches(c) { add(c.ref) } }
            if i.allowPaidEveryday { for c in fits where !c.free { add(c.ref) } }
            return out
        }
    }
}
