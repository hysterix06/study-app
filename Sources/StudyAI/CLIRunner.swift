import Foundation

/// Runs an AI command-line tool headlessly with the Study Tracker MCP server attached. Only Claude Code is wired up:
/// its flags are verified, and invoking the official `claude` binary is the supported way to use a Claude plan from
/// scripts. Other CLIs (Codex, Copilot, Gemini) are offered in the AI apps gallery as MCP connections instead.
/// Never available in sandboxed (App Store) builds.
public enum CLIRunner {
    public struct Output: Sendable { public var stdout: Data; public var stderr: Data; public var status: Int32 }

    /// Finds the `claude` CLI: PATH, the standalone installer locations, or an editor extension's bundled binary.
    public static func findClaude(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        #if os(Windows)
        let exe = "claude.exe"
        let sep: Character = ";"
        #else
        let exe = "claude"
        let sep: Character = ":"
        #endif
        var candidates: [URL] = []
        for dir in (environment["PATH"] ?? "").split(separator: sep).map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(exe))
        }
        candidates += [home.appendingPathComponent(".local/bin/\(exe)"), home.appendingPathComponent(".claude/local/\(exe)"),
                       home.appendingPathComponent(".npm-global/bin/\(exe)")]
        for editor in [".vscode", ".cursor", ".vscode-insiders", ".windsurf"] {
            let ext = home.appendingPathComponent("\(editor)/extensions")
            let dirs = ((try? fm.contentsOfDirectory(atPath: ext.path)) ?? []).filter { $0.hasPrefix("anthropic.claude-code") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += dirs.map { ext.appendingPathComponent($0).appendingPathComponent("resources/native-binary/\(exe)") }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Runs a process, reading stdout and stderr at the same time. Reading one to the end before the other deadlocks
    /// as soon as the other fills its pipe buffer (64 KB), which a chatty CLI does easily. `input` is written to
    /// stdin (then closed), so long prompts never hit the command-line length limit.
    public static func run(_ executable: URL, arguments: [String], directory: URL, environment: [String: String],
                           timeout: TimeInterval, input: Data? = nil, onStart: @escaping (Process) -> Void = { _ in }) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            p.currentDirectoryURL = directory
            p.environment = environment
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            let inPipe = input.map { _ in Pipe() }
            p.standardInput = inPipe ?? FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(throwing: error); return }
            onStart(p)
            if let input, let inPipe {
                DispatchQueue.global(qos: .userInitiated).async {
                    // A CLI can exit without reading its input (a rejected option); writing then must fail quietly
                    // instead of raising SIGPIPE, which would end the app.
                    let h = inPipe.fileHandleForWriting
                    CLIRunner.ignoreBrokenPipe(h)
                    try? h.write(contentsOf: input)
                    try? h.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            let group = DispatchGroup()
            let collected = Collected()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { collected.set(stdout: out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { collected.set(stderr: err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            DispatchQueue.global(qos: .userInitiated).async {
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: Output(stdout: collected.stdout, stderr: collected.stderr, status: p.terminationStatus))
            }
        }
    }

    private static func ignoreBrokenPipe(_ h: FileHandle) {
        #if canImport(Darwin)
        _ = fcntl(h.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        _ = ignoreSIGPIPE
        #endif
    }

    #if !canImport(Darwin)
    private static let ignoreSIGPIPE: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
    #endif

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func set(stdout d: Data) { lock.withLock { out = d } }
        func set(stderr d: Data) { lock.withLock { err = d } }
        var stdout: Data { lock.withLock { out } }
        var stderr: Data { lock.withLock { err } }
    }

    // MARK: Claude Code

    /// One command-line flag. Optional flags are dropped and the run retried when an older Claude Code doesn't know
    /// them, so a new flag never breaks a student's older install.
    struct Flag: Equatable {
        var name: String
        var values: [String] = []
        var optional = false
        /// A word an error about this flag would contain, when it might not quote the flag itself.
        var keyword: String?
    }

    /// The flag an older CLI rejected ("error: unknown option '--safe-mode'"), if it is one we can drop.
    static func rejectedFlag(_ message: String, in flags: [Flag]) -> Int? {
        let m = message.lowercased()
        guard m.contains("unknown option") || m.contains("unknown argument") || m.contains("invalid") || m.contains("not supported") else { return nil }
        return flags.firstIndex { $0.optional && (m.contains($0.name) || $0.keyword.map(m.contains) == true) }
    }

    /// Runs `claude`, dropping optional flags the installed version rejects.
    static func runClaudeCLI(_ cli: URL, flags: [Flag], input: Data?, directory: URL, timeout: TimeInterval,
                             onStart: @escaping (Process) -> Void) async throws -> Output {
        var flags = flags
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<4 {
            let output: Output
            do {
                output = try await run(cli, arguments: flags.flatMap { [$0.name] + $0.values }, directory: directory, environment: env,
                                       timeout: timeout, input: input, onStart: onStart)
            } catch {
                throw AIError.unavailable("Claude Code couldn't start: \(error.localizedDescription)")
            }
            let message = String(decoding: output.stderr + output.stdout.prefix(2000), as: UTF8.self)
            if output.status != 0, let i = rejectedFlag(message, in: flags) { flags.remove(at: i); continue }
            return output
        }
        throw AIError.unavailable("Claude Code rejected its options. Update it with `claude update`.")
    }

    /// Reads `--output-format json`: the reply and what it used. Input tokens include prompt-cache reads and writes,
    /// since they count toward a plan's limits too.
    static func parseResult(_ output: Output) throws -> (text: String, usage: Usage, turns: Int) {
        if output.status == 15 || output.status == 9 || output.status == 143 { throw AIError.canceled }
        guard let v = try? JSONValue.parse(output.stdout) else {
            let lastLine = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            throw friendly(lastLine.isEmpty ? "Claude Code didn't answer (exit \(output.status))." : lastLine)
        }
        let result = v["result"]?.string ?? ""
        if v["is_error"]?.bool == true || v["subtype"]?.string?.hasPrefix("error") == true {
            throw friendly(result.isEmpty ? (v["subtype"]?.string ?? "Claude Code reported an error") : result)
        }
        let u = v["usage"]
        let input = (u?["input_tokens"]?.int ?? 0) + (u?["cache_creation_input_tokens"]?.int ?? 0) + (u?["cache_read_input_tokens"]?.int ?? 0)
        return (result, Usage(inputTokens: input, outputTokens: u?["output_tokens"]?.int ?? 0, costUSD: nil), v["num_turns"]?.int ?? 1)
    }

    /// Flags every Study Tracker run of Claude Code shares: JSON out, the chosen model, nothing saved to the
    /// student's session history, and none of their own setup (CLAUDE.md, plugins, hooks, skills, MCP servers) loaded.
    /// Each of those would otherwise be sent with every request and billed to their plan.
    static func baseFlags(model: String?) -> [Flag] {
        var flags = [Flag(name: "-p"), Flag(name: "--output-format", values: ["json"])]
        if let model, !model.isEmpty {
            flags.append(Flag(name: "--model", values: [model]))
            // Extraction needs little reasoning; Haiku has no effort setting.
            if !model.lowercased().contains("haiku") { flags.append(Flag(name: "--effort", values: ["low"], optional: true, keyword: "effort")) }
        }
        flags += [Flag(name: "--no-session-persistence", optional: true), Flag(name: "--safe-mode", optional: true),
                  Flag(name: "--disable-slash-commands", optional: true)]
        return flags
    }

    /// `claude -p` with only the Study Tracker tools allowed, for tasks where the model explores (weekly plan, exam
    /// patterns). Capped at `maxTurns` so it can't run on and on. Returns Claude's final reply and what it used.
    public static func runClaude(cli: URL, prompt: String, mcpCommand: String, mcpEnvironment: [String: String],
                                 workingDirectory: URL, readableDirectory: URL, model: String? = nil, maxTurns: Int = 16,
                                 timeout: TimeInterval = 15 * 60, onStart: @escaping (Process) -> Void = { _ in }) async throws -> (text: String, usage: Usage) {
        let config = JSONValue.object([("mcpServers", .object([("study-tracker", .object([
            ("command", .string(mcpCommand)), ("args", .array([])),
            ("env", .object(mcpEnvironment.keys.sorted().map { ($0, .string(mcpEnvironment[$0]!)) })),
        ]))]))]).serialized()
        let flags = baseFlags(model: model) + [
            Flag(name: "--mcp-config", values: [config]), Flag(name: "--strict-mcp-config"),
            Flag(name: "--allowedTools", values: ["mcp__study-tracker", "Read"]),
            Flag(name: "--tools", values: ["Read"], optional: true),
            Flag(name: "--max-turns", values: ["\(maxTurns)"]),
            Flag(name: "--add-dir", values: [readableDirectory.path]),
        ]
        let output = try await runClaudeCLI(cli, flags: flags, input: Data(prompt.utf8), directory: workingDirectory, timeout: timeout, onStart: onStart)
        let r = try parseResult(output)
        return (r.text, r.usage)
    }

    /// Turns Claude Code's messages into ones a student can act on.
    static func friendly(_ message: String) -> AIError {
        let m = message.lowercased()
        if m.contains("/login") || m.contains("not logged in") || m.contains("invalid api key") || m.contains("please run") && m.contains("login") || m.contains("authentication") {
            return .auth("Claude Code isn't signed in. Open Terminal, run `claude`, and sign in with your Claude account.")
        }
        if m.contains("usage limit") || m.contains("limit reached") || m.contains("rate limit") {
            return .quotaExhausted(message: "Your Claude plan's usage limit is reached.", resetAt: nil)
        }
        if m.contains("credit balance") { return .quotaExhausted(message: "Claude Code is using an API key with no credit left.", resetAt: nil) }
        if m.contains("max_turns") || m.contains("maximum number of turns") {
            return .budgetExceeded("Stopped: Claude Code reached this task's step limit, so it couldn't use more of your plan.")
        }
        return .badResponse(String(message.prefix(200)))
    }
}

/// Claude Code as a plain text engine for the app's pipelines: one `claude -p` per request with no tools, no MCP
/// servers and a short system prompt. A lecture then costs a few requests of roughly its own size, where letting
/// Claude Code drive the tools re-sent the whole growing conversation (slides, pictures and Claude Code's own
/// instructions) on each of 20 or more turns.
public struct ClaudeCodeProvider: LLMProvider {
    public static let models = [
        ModelInfo(id: "haiku", name: "Haiku (lightest on your plan)", contextTokens: 200_000, tools: false, free: true, priceInPerM: 0, priceOutPerM: 0),
        ModelInfo(id: "sonnet", name: "Sonnet (recommended)", contextTokens: 200_000, tools: false, free: true, priceInPerM: 0, priceOutPerM: 0),
        ModelInfo(id: "opus", name: "Opus (uses your plan fastest)", contextTokens: 200_000, tools: false, free: true, priceInPerM: 0, priceOutPerM: 0),
    ]
    public static let defaultModel = "sonnet"

    /// Not in the catalog (it isn't an API): the job runner builds it directly. Marked free with zero prices because
    /// it bills the student's plan, not money; the per-job token cap still applies.
    public static let descriptor = ProviderDescriptor(id: EngineRef.claudeCode.providerId, name: "Claude Code", kind: .anthropic, auth: .none,
                                                      dataUse: .noTraining, hasFreeOption: true, blurb: "Your Claude plan, through the Claude Code app.",
                                                      editions: [.macDirect, .crossPlatform], models: models, suggestedModel: defaultModel)

    public let cli: URL
    public let workingDirectory: URL
    public let timeout: TimeInterval
    public var descriptor: ProviderDescriptor { Self.descriptor }

    public init(cli: URL, workingDirectory: URL, timeout: TimeInterval = 10 * 60) {
        self.cli = cli; self.workingDirectory = workingDirectory; self.timeout = timeout
    }

    /// The conversation as one prompt: the system text replaces Claude Code's own instructions, the rest is a
    /// transcript (pipelines send one user turn, or a re-ask after broken JSON).
    static func flatten(_ req: ChatRequest) -> (system: String, prompt: String) {
        var system = req.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        if let schema = req.responseSchema { system += (system.isEmpty ? "" : "\n\n") + SchemaPrompt.instruction(schema) }
        let turns = req.messages.filter { $0.role != .system }
        let prompt = turns.count == 1 ? turns[0].text : turns.map { m in
            (m.role == .assistant ? "Your earlier reply:\n" : "") + m.text
        }.joined(separator: "\n\n")
        return (system, prompt)
    }

    public func send(_ req: ChatRequest) async throws -> ChatResponse {
        let (system, prompt) = Self.flatten(req)
        let flags = CLIRunner.baseFlags(model: req.model) + [
            CLIRunner.Flag(name: "--system-prompt", values: [system.isEmpty ? "You are a careful study assistant." : system]),
            CLIRunner.Flag(name: "--tools", values: [""], optional: true),
            CLIRunner.Flag(name: "--strict-mcp-config"), CLIRunner.Flag(name: "--mcp-config", values: [#"{"mcpServers":{}}"#]),
            CLIRunner.Flag(name: "--max-turns", values: ["2"]),
        ]
        let running = RunningProcess()
        let output = try await withTaskCancellationHandler {
            try await CLIRunner.runClaudeCLI(cli, flags: flags, input: Data(prompt.utf8), directory: workingDirectory, timeout: timeout) { running.set($0) }
        } onCancel: { running.terminate() }
        if Task.isCancelled { throw AIError.canceled }
        // Not a network error: those are retried, and a stuck request shouldn't be paid for three times.
        if output.status == 15 { throw AIError.badResponse("Claude Code took longer than \(Int(timeout / 60)) minutes.") }
        let r = try CLIRunner.parseResult(output)
        return ChatResponse(text: r.text, usage: r.usage, finishReason: "stop")
    }
}

/// The process behind a request, so canceling the job stops it.
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var canceled = false
    func set(_ p: Process) {
        let stop = lock.withLock { process = p; return canceled }
        if stop { p.terminate() }
    }
    func terminate() {
        let p = lock.withLock { canceled = true; return process }
        if p?.isRunning == true { p?.terminate() }
    }
}
