import Foundation
import AppKit
import Network
import StudyCore
import StudyAI

/// Everything AI that the app needs outside a single job: where the MCP server is, which engines can run here, the
/// student's choices, and connections to their AI apps.
@MainActor
final class AIService {
    let store: StudyStore
    let secrets: SecretStore = KeychainSecretStore()
    let edition = Edition.current
    var settings: AISettings { AISettings(store: store) }
    var factory: ProviderFactory { ProviderFactory(secrets: secrets, settings: settings) }
    private var cachedCLI: URL??

    init(store: StudyStore) { self.store = store }

    // MARK: MCP server

    /// study-mcp ships inside the app bundle (Contents/MacOS); in development it sits next to the app binary.
    var mcpBinary: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/study-mcp"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("study-mcp"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var mcpbBundle: URL? { Bundle.main.url(forResource: "study-tracker", withExtension: "mcpb") }

    var launch: MCPLaunch {
        MCPLaunch(command: mcpBinary?.path ?? "/Applications/Study Tracker.app/Contents/MacOS/study-mcp",
                  env: ["STUDY_DB_PATH": store.paths.database.path, "STUDY_ROOT": store.paths.root.path])
    }

    // MARK: Claude Code

    /// The `claude` CLI, if installed. Never used by sandboxed (App Store) builds.
    func claudeCLI() -> URL? {
        guard !edition.isSandboxed else { return nil }
        if let cached = cachedCLI { return cached }
        let found = CLIRunner.findClaude()
        cachedCLI = .some(found)
        return found
    }

    func resetCLICache() { cachedCLI = nil }

    /// The model Claude Code builds courses on ("haiku", "sonnet" or "opus").
    var claudeModel: String {
        let m = store.setting("claude_code_model") ?? ""
        return ClaudeCodeProvider.models.contains { $0.id == m } ? m : ClaudeCodeProvider.defaultModel
    }

    /// An empty folder for Claude Code to run in, so no project's CLAUDE.md, settings or MCP servers load with it.
    var claudeWorkingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StudyTracker-claude", isDirectory: true)
    }

    // MARK: Engines

    enum ProviderStatus: Equatable {
        case ready, needsKey, needsConsent, unavailable(String)
        var isReady: Bool { self == .ready }
    }

    func status(_ d: ProviderDescriptor) -> ProviderStatus {
        if d.isApple {
            let a = AppleProviders.availability(d)
            if !a.available { return .unavailable(a.reason ?? "Not available here.") }
        }
        if !factory.hasKey(d) { return .needsKey }
        if settings.needsConsent(d) { return .needsConsent }
        return .ready
    }

    /// Providers to show in this edition. Apple's cloud model only appears where it can work.
    var providers: [ProviderDescriptor] {
        Catalog.available(in: edition).filter { $0.id != Catalog.applePCC.id || edition.isSandboxed }
    }

    /// The model an engine runs: the student's pick, the catalog's suggestion, or OpenRouter's best free model. Nil
    /// when nothing is known yet (a local server or OpenRouter before its model list loads): such an engine can't run.
    func model(for d: ProviderDescriptor) -> String? {
        if d.isApple { return nil }
        return settings.model(forProvider: d.id) ?? d.suggestedModel
            ?? (d.id == Catalog.openRouter.id ? Catalog.bestFreeModel(settings.descriptor(d.id)?.models ?? [])?.id : nil)
            ?? settings.cachedModels(d.id).first?.id
    }

    /// Engines that can run right now, with what their models can do, for the resolver and the pickers.
    func readyEngines() -> [EngineCandidate] {
        providers.filter { status($0).isReady }.compactMap { d -> EngineCandidate? in
            let model = self.model(for: d)
            if !d.isApple && model == nil { return nil }
            let info = model.flatMap { settings.descriptor(d.id)?.model($0) } ?? d.models.first
            return EngineCandidate(ref: EngineRef(d.id, model: model), free: d.runsLocally || d.isApple || (info?.free ?? false),
                                   contextTokens: info?.contextTokens ?? 32_000, tools: info?.tools ?? true,
                                   appleOnDevice: d.id == Catalog.appleOnDevice.id, appleCloud: d.id == Catalog.applePCC.id,
                                   local: d.runsLocally && !d.isApple, strong: d.id == Catalog.anthropic.id)
        }
    }

    /// Free daily allowances already used up today.
    var exhaustedProviders: Set<String> {
        store.aiRequestsToday(provider: Catalog.openRouter.id) >= settings.openRouterFreePerDay ? [Catalog.openRouter.id] : []
    }

    func resolverInputs() -> EngineResolver.Inputs {
        // Claude Code builds with no tools (the course goes in the prompt), so it doesn't need the Study Tracker server.
        EngineResolver.Inputs(ready: readyEngines(), cliAvailable: claudeCLI() != nil, everyday: settings.everyday,
                              builder: settings.builder, allowPaidEveryday: settings.allowPaidEveryday, exhausted: exhaustedProviders)
    }

    /// The engines a task tries, best first. The job runner moves down the list when one fails.
    func candidates(for task: AITask) -> [EngineRef] { EngineResolver.candidates(for: task, resolverInputs()) }

    /// The engine a task starts on.
    func engine(for task: AITask) -> EngineRef? { candidates(for: task).first }

    struct EngineOption: Identifiable, Hashable {
        var ref: EngineRef
        var title: String
        var free: Bool
        var id: String { ref.string }
    }

    /// Engines the student can pick right now: ready providers (with their model) and Claude Code.
    func engineOptions() -> [EngineOption] {
        var out = readyEngines().map { EngineOption(ref: $0.ref, title: $0.ref.displayName, free: $0.free) }
        if claudeCLI() != nil { out.append(EngineOption(ref: .claudeCode, title: EngineRef.claudeCode.displayName, free: false)) }
        return out
    }

    func fit(_ task: AITask, _ ref: EngineRef) -> TaskFit {
        TaskFit.of(task, model: ref.model.flatMap { settings.descriptor(ref.providerId)?.model($0) } ?? ref.descriptor?.models.first, providerId: ref.providerId)
    }

    func provider(_ ref: EngineRef) throws -> LLMProvider { try factory.make(ref, edition: edition) }

    /// Pipelines on the best engine for a task that runs right away, in a session (checking an answer): the next engine
    /// is tried when one fails. Nil when no AI is set up.
    func inline<T>(_ task: AITask, _ work: @escaping (Pipelines) async throws -> T) async throws -> T? {
        var lastError: Error?
        for ref in candidates(for: task).filter({ !$0.isCLI }).prefix(3) {
            do {
                let p = try provider(ref)
                guard let model = ref.model ?? p.descriptor.suggestedModel else { continue }
                let host = try MCPToolHost(paths: store.paths, allowed: [])
                return try await work(Pipelines(provider: p, model: model, host: host, store: store, meter: StoreUsageMeter(store: store)))
            } catch AIError.canceled { throw AIError.canceled }
            catch { lastError = error }
        }
        if let lastError { throw lastError }
        return nil
    }

    /// Refreshes a provider's model list (and caches it) for pickers and capability checks.
    func refreshModels(_ d: ProviderDescriptor) async throws -> [ModelInfo] {
        let p = try factory.make(EngineRef(d.id), edition: edition, requireConsent: false)
        let models = try await p.listModels()
        settings.setCachedModels(d.id, models)
        return models
    }

    // MARK: Keys and sign-in

    func setKey(_ key: String, for d: ProviderDescriptor) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { secrets.delete(AISettings.keyAccount(d.id)) } else { secrets.set(trimmed, account: AISettings.keyAccount(d.id)) }
        store.audit(trimmed.isEmpty ? "ai_key_removed" : "ai_key_added", detail: d.id)
    }

    func hasKey(_ d: ProviderDescriptor) -> Bool { secrets.exists(AISettings.keyAccount(d.id)) }

    /// "Sign in with OpenRouter": opens the browser and catches the callback on a loopback port.
    func signInWithOpenRouter() async throws {
        let auth = OpenRouterAuth()
        let receiver = try LoopbackReceiver()
        let callback = URL(string: "http://localhost:\(receiver.port)/openrouter")!
        NSWorkspace.shared.open(auth.authorizeURL(callback: callback))
        let code = try await receiver.waitForCode(timeout: 300)
        let key = try await auth.exchange(code: code)
        setKey(key, for: Catalog.openRouter)
        _ = try? await refreshModels(Catalog.openRouter)
    }

    // MARK: AI apps (MCP)

    func isInstalled(_ c: AIAppConnector) -> Bool {
        if c.bundleIds.contains(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) { return true }
        if !c.cliNames.isEmpty, !edition.isSandboxed {
            let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
            for name in c.cliNames where path.split(separator: ":").contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }) { return true }
            if c.id == "claude-code", claudeCLI() != nil { return true }
        }
        return c.markers.contains { FileManager.default.fileExists(atPath: Connectors.expand($0).path) }
    }

    func state(_ c: AIAppConnector) -> Connectors.State {
        if c.id == "claude-desktop", Connectors.state(of: c, launch: launch) == .notConnected, extensionInstalled { return .connected }
        if c.id == "claude-code" { return lastUsed(c) != nil ? .connected : .unknown }
        return Connectors.state(of: c, launch: launch)
    }

    /// When the app last talked to Study Tracker's server, from the client name it reported.
    func lastUsed(_ c: AIAppConnector) -> Date? {
        store.mcpClients().first { c.matches(clientName: $0.name) }?.lastSeen
    }

    var extensionInstalled: Bool {
        let dir = Connectors.expand("~/Library/Application Support/Claude/Claude Extensions")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.lowercased().contains("study-tracker") }
    }

    /// Connects an app the safest way it supports: its own CLI or install link, then a strict-JSON edit, then
    /// a snippet for the student to paste. Returns what to tell the student.
    func connect(_ c: AIAppConnector) async throws -> String {
        guard mcpBinary != nil else { throw AIError.unavailable("The Study Tracker server wasn't found in the app bundle.") }
        let l = launch
        if edition.isSandboxed {
            // Sandboxed builds can't edit other apps' files or run their CLIs.
            if c.id == "claude-desktop", installExtension() { return "Claude opened the Study Tracker extension. Click Install there." }
            copy(c.snippet(l))
            return "Copied the setup snippet. Paste it into \(c.name)'s MCP settings."
        }
        switch c.id {
        case "claude-code":
            guard let cli = claudeCLI() else { throw AIError.unavailable("Claude Code isn't installed.") }
            let out = try await CLIRunner.run(cli, arguments: Connectors.claudeCodeArguments(l), directory: store.paths.root,
                                              environment: ProcessInfo.processInfo.environment, timeout: 30)
            if out.status != 0 {
                let msg = String(decoding: out.stderr + out.stdout, as: UTF8.self)
                if msg.lowercased().contains("already exists") { return "Claude Code already has Study Tracker." }
                throw AIError.badResponse(String(msg.prefix(200)))
            }
            return "Added to Claude Code. New Claude Code sessions can use Study Tracker."
        case "vscode":
            if case .jsonFile(let path, let key, _) = c.method {
                do { try Connectors.upsertJSON(at: Connectors.expand(path), key: key, entry: c.entry(l)); return c.afterConnect }
                catch Connectors.ConfigError.commented {
                    if let url = Connectors.vscodeInstallURL(l) { NSWorkspace.shared.open(url); return "VS Code opened its install page. Click Install there." }
                    throw Connectors.ConfigError.commented("mcp.json")
                }
            }
        default: break
        }
        switch c.method {
        case .jsonFile(let path, let key, _):
            do {
                try Connectors.upsertJSON(at: Connectors.expand(path), key: key, entry: c.entry(l))
            } catch Connectors.ConfigError.commented(let f) where c.id == "cursor" || c.id == "lmstudio" {
                let link = c.id == "cursor" ? Connectors.cursorInstallURL(l) : Connectors.lmStudioInstallURL(l)
                if let link { NSWorkspace.shared.open(link); return "\(c.name) opened its install page. Confirm there." }
                throw Connectors.ConfigError.commented(f)
            }
            store.audit("ai_app_connected", detail: c.id)
            return [ "Connected.", c.afterConnect ].filter { !$0.isEmpty }.joined(separator: " ")
        case .tomlAppend(let path):
            try Connectors.appendTOML(at: Connectors.expand(path), launch: l)
            store.audit("ai_app_connected", detail: c.id)
            return [ "Connected.", c.afterConnect ].filter { !$0.isEmpty }.joined(separator: " ")
        case .manual:
            copy(c.snippet(l))
            return "Copied the setup snippet. \(c.manualSteps.first ?? "Paste it into the app's MCP settings.")"
        }
    }

    func disconnect(_ c: AIAppConnector) throws {
        switch c.method {
        case .jsonFile(let path, let key, _): try Connectors.removeJSON(at: Connectors.expand(path), key: key)
        case .tomlAppend: throw AIError.unavailable("Remove the [mcp_servers.study-tracker] section from ~/.codex/config.toml by hand.")
        case .manual: throw AIError.unavailable("Remove Study Tracker in \(c.name)'s own settings.")
        }
        store.audit("ai_app_disconnected", detail: c.id)
    }

    func installExtension() -> Bool {
        guard let mcpb = mcpbBundle, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else { return false }
        NSWorkspace.shared.open([mcpb], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// The AI app a handoff opens: the student's choice, else the first connected one, else Claude Desktop.
    var handoffApp: AIAppConnector? {
        if let id = store.setting("ai_handoff_app"), let c = Connectors.connector(id) { return c }
        return Connectors.all.first { isInstalled($0) && state($0) == .connected && !$0.bundleIds.isEmpty }
            ?? Connectors.connector("claude-desktop").flatMap { isInstalled($0) ? $0 : nil }
    }

    func open(_ c: AIAppConnector) {
        for id in c.bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

extension AISettings {
    /// The model last chosen for a provider.
    func engine(forProvider id: String) -> String? { model(forProvider: id) }
}

/// A one-shot HTTP listener on 127.0.0.1 that catches an OAuth redirect (`/openrouter?code=…`).
final class LoopbackReceiver: @unchecked Sendable {
    let listener: NWListener
    private(set) var port: UInt16 = 0
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        guard let p = listener.port?.rawValue, p != 0 else { throw AIError.unavailable("Couldn't open a local port for sign-in.") }
        port = p
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { c in
            lock.withLock { continuation = c }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(AIError.auth("Sign-in timed out. Try again.")))
            }
        }
    }

    private func finish(_ r: Result<String, Error>) {
        let c: CheckedContinuation<String, Error>? = lock.withLock { let c = continuation; continuation = nil; return c }
        c?.resume(with: r)
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .global())
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let code = URLComponents(string: "http://localhost\(path)")?.queryItems?.first { $0.name == "code" }?.value
            let body = code != nil ? "<h2>Signed in. You can close this tab and return to Study Tracker.</h2>" : "<h2>Sign-in didn't finish. Return to Study Tracker and try again.</h2>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            c.send(content: Data(response.utf8), completion: .contentProcessed { _ in c.cancel() })
            if let code { self?.finish(.success(code)) } else if path.hasPrefix("/openrouter") { self?.finish(.failure(AIError.auth("OpenRouter sign-in was canceled."))) }
        }
    }
}
