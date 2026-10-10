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
    /// as soon as the other fills its pipe buffer (64 KB), which a chatty CLI does easily.
    public static func run(_ executable: URL, arguments: [String], directory: URL, environment: [String: String],
                           timeout: TimeInterval, onStart: @escaping (Process) -> Void = { _ in }) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            p.currentDirectoryURL = directory
            p.environment = environment
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(throwing: error); return }
            onStart(p)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            let group = DispatchGroup()
            var stdout = Data(), stderr = Data()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { stdout = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { stderr = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            DispatchQueue.global(qos: .userInitiated).async {
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: Output(stdout: stdout, stderr: stderr, status: p.terminationStatus))
            }
        }
    }

    /// `claude -p` with the Study Tracker tools and nothing else: no files, no shell, no web (`--tools ""` turns off
    /// every built-in tool), and no other MCP servers the student has set up. Pictures from slides come through the
    /// Study Tracker tools. The run isn't kept in the student's Claude Code history. Returns Claude's final reply.
    public static func runClaude(cli: URL, prompt: String, mcpCommand: String, mcpEnvironment: [String: String],
                                 workingDirectory: URL, model: String? = nil, timeout: TimeInterval = 30 * 60,
                                 onStart: @escaping (Process) -> Void = { _ in }) async throws -> String {
        let config = JSONValue.object([("mcpServers", .object([("study-tracker", .object([
            ("command", .string(mcpCommand)), ("args", .array([])),
            ("env", .object(mcpEnvironment.keys.sorted().map { ($0, .string(mcpEnvironment[$0]!)) })),
        ]))]))]).serialized()
        var args = arguments(prompt: prompt, config: config)
        if let model, !model.isEmpty { args += ["--model", model] }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        let output: Output
        do {
            output = try await run(cli, arguments: args, directory: workingDirectory, environment: env, timeout: timeout, onStart: onStart)
        } catch {
            throw AIError.unavailable("Claude Code couldn't start: \(error.localizedDescription)")
        }
        if output.status == 15 || output.status == 9 { throw AIError.canceled }
        if let v = try? JSONValue.parse(output.stdout) {
            let result = v["result"]?.string ?? ""
            if v["is_error"]?.bool == true { throw friendly(result.isEmpty ? "Claude Code reported an error" : result) }
            return result
        }
        let lastLine = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        throw friendly(lastLine.isEmpty ? "Claude Code didn't answer (exit \(output.status))." : lastLine)
    }

    /// Checked against Claude Code 2.1.292: with `--tools ""` the MCP tools stay callable and Read, Bash and the rest
    /// are gone.
    static func arguments(prompt: String, config: String) -> [String] {
        ["-p", prompt, "--mcp-config", config, "--strict-mcp-config", "--tools", "", "--allowedTools", "mcp__study-tracker",
         "--no-session-persistence", "--output-format", "json"]
    }

    /// Turns Claude Code's messages into ones a student can act on.
    static func friendly(_ message: String, now: Date = Date()) -> AIError {
        let m = message.lowercased()
        if m.contains("/login") || m.contains("not logged in") || m.contains("invalid api key") || m.contains("please run") && m.contains("login") || m.contains("authentication") {
            return .auth("Claude Code isn't signed in. Open Terminal, run `claude`, and sign in with your Claude account.")
        }
        if m.contains("usage limit") || m.contains("limit reached") || m.contains("rate limit") || m.contains("session limit")
            || m.contains("weekly limit") || (m.contains("hit your") && m.contains("limit")) {
            return .quotaExhausted(message: "Your Claude plan's usage limit is reached.", resetAt: resetTime(in: message, now: now))
        }
        if m.contains("credit balance") { return .quotaExhausted(message: "Claude Code is using an API key with no credit left.", resetAt: nil) }
        return .badResponse(String(message.prefix(200)))
    }

    /// When a plan limit lifts: "…|1790000000", or "resets 10:40pm (Europe/Madrid)", the next time that clock time
    /// comes round.
    static func resetTime(in message: String, now: Date = Date()) -> Date? {
        if let r = message.range(of: #"\|(\d{10})\b"#, options: .regularExpression), let t = Double(message[r].dropFirst()) {
            return Date(timeIntervalSince1970: t)
        }
        guard let re = try? NSRegularExpression(pattern: #"(?i)resets\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*\(([^)]+)\))?"#),
              let match = re.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: message).map { String(message[$0]) } }
        guard var hour = group(1).flatMap(Int.init), hour < 24 else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        switch group(3)?.lowercased() {
        case "pm" where hour < 12: hour += 12
        case "am" where hour == 12: hour = 0
        default: break
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = group(4).flatMap(TimeZone.init(identifier:)) ?? .current
        return cal.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
    }
}
