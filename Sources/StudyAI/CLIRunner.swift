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

    /// `claude -p` with only the Study Tracker tools allowed. Returns Claude's final reply.
    public static func runClaude(cli: URL, prompt: String, mcpCommand: String, mcpEnvironment: [String: String],
                                 workingDirectory: URL, readableDirectory: URL, timeout: TimeInterval = 20 * 60,
                                 onStart: @escaping (Process) -> Void = { _ in }) async throws -> String {
        let config = JSONValue.object([("mcpServers", .object([("study-tracker", .object([
            ("command", .string(mcpCommand)), ("args", .array([])),
            ("env", .object(mcpEnvironment.keys.sorted().map { ($0, .string(mcpEnvironment[$0]!)) })),
        ]))]))]).serialized()
        let args = ["-p", prompt, "--mcp-config", config, "--strict-mcp-config",
                    "--allowedTools", "mcp__study-tracker", "Read",
                    "--add-dir", readableDirectory.path, "--output-format", "json"]
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
        return .badResponse(String(message.prefix(200)))
    }
}
