import Foundation
import AppKit
import StudyCore

/// Connects the app to Claude: the MCP server for Claude Desktop, and optional headless runs through Claude Code.
final class ClaudeService {
    private var cachedCLI: URL??

    // MARK: MCP server location

    /// study-mcp ships inside the app bundle (Contents/MacOS); in development it sits next to the app binary.
    var mcpBinary: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/study-mcp"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("study-mcp"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var mcpbBundle: URL? { Bundle.main.url(forResource: "study-tracker", withExtension: "mcpb") }

    var desktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    var claudeDesktopInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil }

    func configEntry(store: StudyStore) -> [String: Any] {
        ["command": mcpBinary?.path ?? "/Applications/Study Tracker.app/Contents/MacOS/study-mcp",
         "args": [String](),
         "env": ["STUDY_DB_PATH": store.paths.database.path, "STUDY_ROOT": store.paths.root.path]]
    }

    func configSnippet(store: StudyStore) -> String {
        JSON.string(["mcpServers": ["study-tracker": configEntry(store: store)]], pretty: true)
    }

    enum ConnectionState: Equatable { case connected, stalePath(String), extensionInstalled, notConnected }

    func connectionState() -> ConnectionState {
        if let data = try? Data(contentsOf: desktopConfigURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = obj["mcpServers"] as? [String: Any], let entry = servers["study-tracker"] as? [String: Any] {
            let cmd = entry["command"] as? String ?? ""
            if FileManager.default.isExecutableFile(atPath: cmd) {
                if let mine = mcpBinary?.path, mine != cmd { return .stalePath(cmd) }
                return .connected
            }
            return .stalePath(cmd)
        }
        let extDir = desktopConfigURL.deletingLastPathComponent().appendingPathComponent("Claude Extensions")
        if let items = try? FileManager.default.contentsOfDirectory(atPath: extDir.path), items.contains(where: { $0.lowercased().contains("study-tracker") }) {
            return .extensionInstalled
        }
        return .notConnected
    }

    /// Adds (or repairs) the study-tracker entry in Claude Desktop's config, keeping every other setting and a backup.
    func connectDesktop(store: StudyStore) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: desktopConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var obj: [String: Any] = [:]
        var backup: URL?
        if let data = try? Data(contentsOf: desktopConfigURL) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Study", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude Desktop's config file is not valid JSON; it was left untouched."])
            }
            obj = parsed
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            backup = desktopConfigURL.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.backup-\(f.string(from: Date())).json")
            try data.write(to: backup!)
        }
        var servers = obj["mcpServers"] as? [String: Any] ?? [:]
        servers["study-tracker"] = configEntry(store: store)
        obj["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: desktopConfigURL, options: .atomic)
        store.audit("connect_claude_desktop")
        return backup
    }

    func disconnectDesktop() throws {
        guard let data = try? Data(contentsOf: desktopConfigURL),
              var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var servers = obj["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: "study-tracker")
        obj["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: desktopConfigURL, options: .atomic)
    }

    func installExtension() -> Bool {
        guard let mcpb = mcpbBundle,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else { return false }
        NSWorkspace.shared.open([mcpb], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    // MARK: Claude Code (headless)

    /// Finds the `claude` command-line tool: PATH, the standalone installer locations, or an editor extension.
    func findCLI() -> URL? {
        if let cached = cachedCLI { return cached }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("claude"))
        }
        candidates += [home.appendingPathComponent(".local/bin/claude"), home.appendingPathComponent(".claude/local/claude"),
                       home.appendingPathComponent(".npm-global/bin/claude")]
        for editor in [".vscode", ".cursor", ".vscode-insiders", ".windsurf"] {
            let ext = home.appendingPathComponent("\(editor)/extensions")
            let dirs = ((try? fm.contentsOfDirectory(atPath: ext.path)) ?? []).filter { $0.hasPrefix("anthropic.claude-code") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += dirs.map { ext.appendingPathComponent($0).appendingPathComponent("resources/native-binary/claude") }
        }
        let found = candidates.first { fm.isExecutableFile(atPath: $0.path) }
        cachedCLI = .some(found)
        return found
    }

    func resetCLICache() { cachedCLI = nil }

    struct RunError: LocalizedError { var message: String; var errorDescription: String? { message } }

    /// `onStart` hands back the process so a job can be canceled.
    func runHeadless(cli: URL, prompt: String, store: StudyStore, timeout: TimeInterval = 20 * 60,
                     onStart: @escaping (Process) -> Void = { _ in }) async -> Result<String, Error> {
        guard let mcp = mcpBinary else { return .failure(RunError(message: "The Study Tracker MCP server was not found in the app bundle")) }
        let config = JSON.string(["mcpServers": ["study-tracker": [
            "command": mcp.path, "args": [String](),
            "env": ["STUDY_DB_PATH": store.paths.database.path, "STUDY_ROOT": store.paths.root.path],
        ]]])
        let args = ["-p", prompt, "--mcp-config", config, "--strict-mcp-config",
                    "--allowedTools", "mcp__study-tracker", "Read",
                    "--add-dir", store.paths.captures.path, "--output-format", "json"]
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = cli
                p.arguments = args
                p.currentDirectoryURL = store.paths.root
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: .failure(error)); return }
                onStart(p)
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                store.audit("claude_code_run", detail: ["status": Int(p.terminationStatus)])
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let result = obj["result"] as? String ?? ""
                    if (obj["is_error"] as? Bool) == true {
                        cont.resume(returning: .failure(RunError(message: result.isEmpty ? "Claude Code reported an error" : String(result.prefix(200)))))
                    } else {
                        cont.resume(returning: .success(result))
                    }
                } else {
                    let msg = String(data: errData, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
                    cont.resume(returning: .failure(RunError(message: msg.isEmpty ? "Claude Code did not answer" : msg)))
                }
            }
        }
    }
}
