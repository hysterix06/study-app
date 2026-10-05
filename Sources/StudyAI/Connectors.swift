import Foundation

/// How to start the Study Tracker MCP server, as every AI app needs it.
public struct MCPLaunch: Sendable, Equatable {
    public var command: String
    public var env: [String: String]
    public init(command: String, env: [String: String]) { self.command = command; self.env = env }

    var envJSON: JSONValue { .object(env.keys.sorted().map { ($0, .string(env[$0]!)) }) }
    /// The common `{command, args, env}` entry most apps use.
    public var entry: JSONValue { .object([("command", .string(command)), ("args", .array([])), ("env", envJSON)]) }
}

/// One AI app Study Tracker can connect to over MCP, and the safest way to do it.
public struct AIAppConnector: Identifiable, Sendable {
    public enum Method: Sendable, Equatable {
        /// A strict-JSON config file: add the entry under `key`, keeping everything else and its order.
        case jsonFile(path: String, key: String, style: EntryStyle)
        /// Append a TOML table when it isn't there yet (Codex). Existing entries are never rewritten.
        case tomlAppend(path: String)
        /// Only instructions and a snippet: the app has no file Study Tracker should touch (Perplexity, Zed).
        case manual
    }

    public enum EntryStyle: Sendable, Equatable { case standard, vscode, copilotCLI }

    public var id: String
    public var name: String
    public var blurb: String
    /// Plan or price the student needs, said plainly.
    public var plan: String
    /// macOS bundle ids that mean the app is installed.
    public var bundleIds: [String]
    /// CLI names that mean it's installed (and can add the server itself).
    public var cliNames: [String]
    /// Paths that mean it's installed or has been used ("~" expands to home).
    public var markers: [String]
    public var method: Method
    /// Tokens matched (case-insensitively) against the MCP client name the app reports, for "Last used …".
    public var clientNames: [String]
    /// Whether the app lists MCP prompts. When it doesn't, Study Tracker's handoff uses get_task_instructions.
    public var showsPrompts: Bool
    /// What to do after connecting ("Quit and reopen Claude").
    public var afterConnect: String
    /// Manual steps, shown with the snippet.
    public var manualSteps: [String]
    public var free: Bool

    public init(id: String, name: String, blurb: String, plan: String, bundleIds: [String] = [], cliNames: [String] = [], markers: [String] = [],
                method: Method, clientNames: [String], showsPrompts: Bool = false, afterConnect: String = "", manualSteps: [String] = [], free: Bool = false) {
        self.id = id; self.name = name; self.blurb = blurb; self.plan = plan; self.bundleIds = bundleIds; self.cliNames = cliNames; self.markers = markers
        self.method = method; self.clientNames = clientNames; self.showsPrompts = showsPrompts; self.afterConnect = afterConnect
        self.manualSteps = manualSteps; self.free = free
    }

    public func entry(_ launch: MCPLaunch) -> JSONValue {
        switch method {
        case .jsonFile(_, _, .vscode): return .object([("type", "stdio"), ("command", .string(launch.command)), ("args", .array([])), ("env", launch.envJSON)])
        case .jsonFile(_, _, .copilotCLI): return .object([("type", "local"), ("command", .string(launch.command)), ("args", .array([])), ("env", launch.envJSON), ("tools", ["*"])])
        default: return launch.entry
        }
    }

    /// Text the student can paste into the app's settings by hand.
    public func snippet(_ launch: MCPLaunch) -> String {
        switch method {
        case .tomlAppend: return Connectors.tomlTable(launch)
        case .jsonFile(_, let key, _): return JSONValue.object([(key, .object([(Connectors.serverName, entry(launch))]))]).serialized(indent: 2)
        case .manual: return JSONValue.object([("mcpServers", .object([(Connectors.serverName, launch.entry)]))]).serialized(indent: 2)
        }
    }

    public func matches(clientName: String) -> Bool {
        let n = clientName.lowercased()
        return clientNames.contains { n.contains($0) }
    }
}

/// AI apps that can't use a local MCP server, with the honest reason and what to do instead.
public struct UnsupportedAIApp: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var reason: String
}

public enum Connectors {
    public static let serverName = "study-tracker"

    #if os(Windows)
    static let appSupport = "%APPDATA%"
    #elseif os(Linux)
    static let appSupport = "~/.config"
    #else
    static let appSupport = "~/Library/Application Support"
    #endif

    public static let all: [AIAppConnector] = [
        AIAppConnector(
            id: "claude-desktop", name: "Claude Desktop", blurb: "Chat with Claude about your lectures; it saves concepts, questions and sheets here.",
            plan: "Works on the free Claude plan.", bundleIds: ["com.anthropic.claudefordesktop"], markers: ["\(appSupport)/Claude"],
            method: .jsonFile(path: "\(appSupport)/Claude/claude_desktop_config.json", key: "mcpServers", style: .standard),
            clientNames: ["claude-ai", "claude desktop"], showsPrompts: true, afterConnect: "Quit Claude completely and open it again.", free: true),
        AIAppConnector(
            id: "claude-code", name: "Claude Code", blurb: "Claude in the terminal or VS Code. Also runs Study Tracker's background tasks on your Claude plan.",
            plan: "Needs a Claude Pro or Max plan, or an API key.", cliNames: ["claude"], markers: ["~/.claude"],
            method: .manual, clientNames: ["claude-code"], showsPrompts: true),
        AIAppConnector(
            id: "codex", name: "ChatGPT app (Codex) and Codex CLI", blurb: "OpenAI's Codex in the ChatGPT Mac app's Codex tab, the Codex CLI and its IDE extension.",
            plan: "Needs a paid ChatGPT plan. ChatGPT's normal chat can't use local servers.", bundleIds: ["com.openai.chat", "com.openai.codex"], cliNames: ["codex"],
            markers: ["~/.codex"], method: .tomlAppend(path: "~/.codex/config.toml"), clientNames: ["codex", "chatgpt"],
            afterConnect: "Restart Codex (or the ChatGPT app)."),
        AIAppConnector(
            id: "vscode", name: "VS Code with Copilot", blurb: "Copilot's agent mode in VS Code can read your material and save results.",
            plan: "Works with Copilot Free.", bundleIds: ["com.microsoft.VSCode"], cliNames: ["code"],
            method: .jsonFile(path: "\(appSupport)/Code/User/mcp.json", key: "servers", style: .vscode),
            clientNames: ["visual studio code", "vscode"], showsPrompts: true, afterConnect: "In VS Code, open Copilot Chat in Agent mode.", free: true),
        AIAppConnector(
            id: "cursor", name: "Cursor", blurb: "Cursor's agent can use Study Tracker's tools.", plan: "Works on Cursor's free plan (limited requests).",
            bundleIds: ["com.todesktop.230313mzl4w4u92"], markers: ["~/.cursor"],
            method: .jsonFile(path: "~/.cursor/mcp.json", key: "mcpServers", style: .standard), clientNames: ["cursor"], showsPrompts: true,
            afterConnect: "Restart Cursor, then turn Study Tracker on under Settings › MCP.", free: true),
        AIAppConnector(
            id: "lmstudio", name: "LM Studio", blurb: "Free, private models on your own computer, with Study Tracker's tools.",
            plan: "Free. Pick a model with tool support; 16 GB of memory or more works best.", bundleIds: ["ai.elementlabs.lmstudio"], markers: ["~/.lmstudio"],
            method: .jsonFile(path: "~/.lmstudio/mcp.json", key: "mcpServers", style: .standard), clientNames: ["lm studio", "lmstudio"], free: true),
        AIAppConnector(
            id: "windsurf", name: "Windsurf", blurb: "Windsurf's Cascade agent can use Study Tracker's tools.", plan: "Works on Windsurf's free plan.",
            bundleIds: ["com.exafunction.windsurf"], markers: ["~/.codeium/windsurf"],
            method: .jsonFile(path: "~/.codeium/windsurf/mcp_config.json", key: "mcpServers", style: .standard), clientNames: ["windsurf"],
            afterConnect: "Refresh MCP servers in Windsurf's Cascade panel.", free: true),
        AIAppConnector(
            id: "copilot-cli", name: "GitHub Copilot CLI", blurb: "Copilot in the terminal.", plan: "Needs a GitHub Copilot plan (Copilot Free works with limits).",
            cliNames: ["copilot"], markers: ["~/.copilot"], method: .jsonFile(path: "~/.copilot/mcp-config.json", key: "mcpServers", style: .copilotCLI),
            clientNames: ["copilot"], free: true),
        AIAppConnector(
            id: "gemini-cli", name: "Gemini CLI", blurb: "Google's Gemini in the terminal.",
            plan: "Needs a Gemini API key (Google ended free sign-in in June 2026). The free key tier isn't allowed in the EU, UK or Switzerland.",
            cliNames: ["gemini"], markers: ["~/.gemini"], method: .jsonFile(path: "~/.gemini/settings.json", key: "mcpServers", style: .standard),
            clientNames: ["gemini"]),
        AIAppConnector(
            id: "zed", name: "Zed", blurb: "Zed's agent panel can use Study Tracker's tools.", plan: "Works with Zed's free plan or your own key.",
            bundleIds: ["dev.zed.Zed"], method: .manual, clientNames: ["zed"],
            manualSteps: ["Open Zed's settings (Zed › Settings › Open Settings).", "Add the snippet under \"context_servers\" (Zed's settings allow comments, so Study Tracker doesn't edit the file itself).", "Save; Zed starts the server."]),
        AIAppConnector(
            id: "perplexity", name: "Perplexity (Mac)", blurb: "Perplexity's Mac app can use local connectors.", plan: "Needs Perplexity's helper app (PerplexityXPC).",
            bundleIds: ["ai.perplexity.mac"], method: .manual, clientNames: ["perplexity"],
            manualSteps: ["In Perplexity, open Settings › Connectors and install the helper if asked.", "Choose Add Connector › Advanced and paste the snippet.", "Turn the connector on in a new thread."]),
        AIAppConnector(
            id: "other", name: "Another MCP app", blurb: "Any app that supports local (stdio) MCP servers.", plan: "",
            method: .manual, clientNames: [], manualSteps: ["Add a local (stdio) MCP server named study-tracker with this command and environment."]),
    ]

    public static let unsupported: [UnsupportedAIApp] = [
        UnsupportedAIApp(id: "chatgpt", name: "ChatGPT (normal chat)", reason: "ChatGPT only connects to servers on the internet, and only on business plans. Use Copy for any chatbot, or the Codex tab."),
        UnsupportedAIApp(id: "gemini-app", name: "Gemini app", reason: "Google's Gemini app can't connect to other apps. Use Copy for any chatbot, or add a Gemini key under Built-in AI."),
        UnsupportedAIApp(id: "brave-leo", name: "Brave Leo", reason: "Leo can't connect to other apps. Use Copy for any chatbot. For free models without Brave, use OpenRouter under Built-in AI."),
        UnsupportedAIApp(id: "le-chat", name: "Mistral Le Chat", reason: "Le Chat only connects to servers on the internet. Use Copy for any chatbot, or add a Mistral key under Built-in AI."),
        UnsupportedAIApp(id: "claude-ios", name: "Claude, ChatGPT or Gemini on iPhone", reason: "Phone apps can't reach servers on your Mac. The iPhone version of Study Tracker has its own built-in AI."),
    ]

    public static func connector(_ id: String) -> AIAppConnector? { all.first { $0.id == id } }

    public static func expand(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        var p = path
        if p.hasPrefix("~/") { p = home.path + String(p.dropFirst(1)) }
        if p.hasPrefix("%APPDATA%"), let appData = ProcessInfo.processInfo.environment["APPDATA"] { p = appData + String(p.dropFirst(9)) }
        return URL(fileURLWithPath: p)
    }

    // MARK: Config files

    public enum ConfigError: Error, LocalizedError, Equatable {
        case commented(String), invalid(String), notAnObject(String), existingTOMLEntry(String)
        public var errorDescription: String? {
            switch self {
            case .commented(let f): return "\(f) has comments, so Study Tracker won't rewrite it. Use the app's own install button or paste the snippet."
            case .invalid(let f): return "\(f) isn't valid JSON, so it was left untouched."
            case .notAnObject(let f): return "\(f) doesn't have the expected layout, so it was left untouched."
            case .existingTOMLEntry(let f): return "\(f) already has a study-tracker entry. Edit it by hand with the snippet."
            }
        }
    }

    /// Adds or replaces our entry under `key`, keeping every other setting and its order. Re-reads the file right
    /// before writing, writes atomically, and keeps the three newest backups.
    @discardableResult
    public static func upsertJSON(at url: URL, key: String, entry: JSONValue, keepBackups: Int = 3) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: JSONValue = [:]
        var backup: URL?
        if let data = fm.contents(atPath: url.path), !data.isEmpty, !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { root = try JSONValue.parse(data) } catch JSONValue.ParseError.jsonc { throw ConfigError.commented(url.lastPathComponent) } catch { throw ConfigError.invalid(url.lastPathComponent) }
            guard root.object != nil else { throw ConfigError.notAnObject(url.lastPathComponent) }
            backup = try writeBackup(data, for: url, keep: keepBackups)
        }
        var servers = root[key] ?? [:]
        guard servers.object != nil else { throw ConfigError.notAnObject(url.lastPathComponent) }
        if servers[serverName] == entry { return nil }
        servers[serverName] = entry
        root[key] = servers
        try Data((root.serialized(indent: 2) + "\n").utf8).write(to: url, options: .atomic)
        return backup
    }

    /// Removes our entry; everything else stays as it was.
    public static func removeJSON(at url: URL, key: String) throws {
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        var root: JSONValue
        do { root = try JSONValue.parse(data) } catch JSONValue.ParseError.jsonc { throw ConfigError.commented(url.lastPathComponent) } catch { throw ConfigError.invalid(url.lastPathComponent) }
        guard var servers = root[key], servers[serverName] != nil else { return }
        _ = try writeBackup(data, for: url, keep: 3)
        servers[serverName] = nil
        root[key] = servers
        try Data((root.serialized(indent: 2) + "\n").utf8).write(to: url, options: .atomic)
    }

    /// Our entry in a JSON config, or nil (missing file, no entry, or a file we can't read safely).
    public static func readJSONEntry(at url: URL, key: String) -> JSONValue? {
        guard let data = FileManager.default.contents(atPath: url.path), let root = try? JSONValue.parse(data) else { return nil }
        return root[key]?[serverName]
    }

    static func writeBackup(_ data: Data, for url: URL, keep: Int) throws -> URL {
        let fm = FileManager.default
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        let backup = dir.appendingPathComponent("\(stem).backup-\(f.string(from: Date())).\(ext)")
        try data.write(to: backup)
        let prefix = "\(stem).backup-"
        let old = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted(by: >)
        for name in old.dropFirst(keep) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        return backup
    }

    // MARK: TOML (Codex)

    public static func tomlTable(_ launch: MCPLaunch) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let env = launch.env.keys.sorted().map { "\($0) = \(q(launch.env[$0]!))" }.joined(separator: ", ")
        return """
        [mcp_servers.\(serverName)]
        command = \(q(launch.command))
        args = []
        env = { \(env) }
        """
    }

    public static func tomlHasEntry(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s*\[mcp_servers\.("?)study-tracker\1\]"#, options: .regularExpression) != nil
    }

    /// Appends our table to a TOML config when it isn't there. Existing entries are never edited.
    @discardableResult
    public static func appendTOML(at url: URL, launch: MCPLaunch) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = fm.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if tomlHasEntry(existing) {
            if existing.contains(tomlTable(launch)) { return nil }
            throw ConfigError.existingTOMLEntry(url.lastPathComponent)
        }
        var backup: URL?
        if !existing.isEmpty { backup = try writeBackup(Data(existing.utf8), for: url, keep: 3) }
        let sep = existing.isEmpty ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
        try Data((existing + sep + tomlTable(launch) + "\n").utf8).write(to: url, options: .atomic)
        return backup
    }

    // MARK: Status

    public enum State: Equatable, Sendable {
        case connected
        /// The entry points at a server that no longer exists (the app moved).
        case stale(String)
        case notConnected
        /// We can't tell (manual setup); "Last used" is the only signal.
        case unknown
    }

    public static func state(of c: AIAppConnector, launch: MCPLaunch) -> State {
        switch c.method {
        case .jsonFile(let path, let key, _):
            guard let entry = readJSONEntry(at: expand(path), key: key) else { return .notConnected }
            let cmd = entry["command"]?.string ?? ""
            if cmd != launch.command || !FileManager.default.isExecutableFile(atPath: cmd) { return .stale(cmd) }
            return .connected
        case .tomlAppend(let path):
            guard let text = FileManager.default.contents(atPath: expand(path).path).map({ String(decoding: $0, as: UTF8.self) }), tomlHasEntry(text) else { return .notConnected }
            return text.contains(launch.command) ? .connected : .stale("")
        case .manual:
            return .unknown
        }
    }

    // MARK: One-click installs that the apps themselves handle

    /// `claude mcp add` (user scope) for Claude Code.
    public static func claudeCodeArguments(_ launch: MCPLaunch) -> [String] {
        ["mcp", "add", "--scope", "user"] + launch.env.keys.sorted().flatMap { ["-e", "\($0)=\(launch.env[$0]!)"] } + [serverName, "--", launch.command]
    }

    /// VS Code's install link (used when its mcp.json has comments).
    public static func vscodeInstallURL(_ launch: MCPLaunch) -> URL? {
        let json = JSONValue.object([("name", .string(serverName)), ("type", "stdio"), ("command", .string(launch.command)), ("args", .array([])), ("env", launch.envJSON)]).serialized()
        guard let enc = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "vscode:mcp/install?\(enc)")
    }

    public static func cursorInstallURL(_ launch: MCPLaunch) -> URL? {
        let cfg = Data(launch.entry.serialized().utf8).base64EncodedString()
        return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=\(serverName)&config=\(cfg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cfg)")
    }

    public static func lmStudioInstallURL(_ launch: MCPLaunch) -> URL? {
        let cfg = Data(launch.entry.serialized().utf8).base64EncodedString()
        return URL(string: "lmstudio://add_mcp?name=\(serverName)&config=\(cfg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cfg)")
    }
}
