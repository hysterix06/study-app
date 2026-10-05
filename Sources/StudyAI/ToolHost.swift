import Foundation
import StudyCore
import StudyMCPCore

public struct ToolResult: Sendable {
    public var text: String
    public var images: [(Data, String)]
    public var isError: Bool
    public init(text: String, images: [(Data, String)] = [], isError: Bool = false) { self.text = text; self.images = images; self.isError = isError }
}

/// Where an engine's tool calls go.
public protocol ToolHost: Sendable {
    func specs() -> [ToolSpec]
    func call(_ name: String, _ arguments: JSONValue) async -> ToolResult
}

/// The Study Tracker tools, run in-process through `MCPServer` so every engine gets the same rules as an MCP client:
/// no deletes, proposals until confirmed, source chunks required, audit, backup before the first write, job results.
public final class MCPToolHost: ToolHost, @unchecked Sendable {
    let server: MCPServer
    let allowed: Set<String>?
    let jobId: Int?
    /// Tools the model may never call here. In the app's chat, flashcard ratings come from buttons the student taps.
    let blocked: Set<String>
    private let lock = NSLock()

    public init(server: MCPServer, allowed: Set<String>? = nil, blocked: Set<String> = [], jobId: Int? = nil) {
        self.server = server; self.allowed = allowed; self.blocked = blocked; self.jobId = jobId
    }

    /// Opens the database as actor "ai" so the audit log shows which writes came from the built-in AI.
    public convenience init(paths: AppPaths, allowed: Set<String>? = nil, blocked: Set<String> = [], jobId: Int? = nil) throws {
        let store = try StudyStore.open(paths: paths, actor: "ai", migrate: false)
        self.init(server: MCPServer(paths: paths, readOnly: false, store: store), allowed: allowed, blocked: blocked, jobId: jobId)
    }

    func permitted(_ name: String) -> Bool { !blocked.contains(name) && (allowed?.contains(name) ?? true) }

    public func specs() -> [ToolSpec] {
        server.toolDefinitions.compactMap { d -> ToolSpec? in
            guard let name = d["name"] as? String, permitted(name) else { return nil }
            var schema = JSONValue(any: d["inputSchema"])
            // The host adds job_id to writes itself; the model doesn't need to know about it.
            if server.writeToolNames.contains(name), var props = schema["properties"], props["job_id"] != nil {
                props["job_id"] = nil
                schema["properties"] = props
            }
            return ToolSpec(name: name, description: d["description"] as? String ?? "", parameters: schema)
        }
    }

    public func call(_ name: String, _ arguments: JSONValue) async -> ToolResult {
        guard permitted(name) else {
            let why = blocked.contains("log_review") && name == "log_review"
                ? "Ratings are the student's own: ask them to tap Again, Hard, Good or Easy under the card."
                : "That tool isn't available for this task."
            return ToolResult(text: #"{"code":"FORBIDDEN","message":"\#(why)"}"#, isError: true)
        }
        var args = (arguments.any as? [String: Any]) ?? [:]
        if let jobId, server.writeToolNames.contains(name) { args["job_id"] = jobId }
        let result: [String: Any] = lock.withLock { server.callTool(name, args) }
        let content = result["content"] as? [[String: Any]] ?? []
        var text: [String] = []
        var images: [(Data, String)] = []
        for item in content {
            switch item["type"] as? String {
            case "text": text.append(item["text"] as? String ?? "")
            case "image":
                if let b64 = item["data"] as? String, let d = Data(base64Encoded: b64) { images.append((d, item["mimeType"] as? String ?? "image/jpeg")) }
            default: break
            }
        }
        return ToolResult(text: text.joined(separator: "\n"), images: images, isError: result["isError"] as? Bool ?? false)
    }

    /// Direct calls for pipelines, which build the arguments themselves.
    public func callJSON(_ name: String, _ arguments: [String: Any]) async -> (ok: Bool, json: JSONValue?, text: String) {
        let r = await call(name, JSONValue(any: arguments))
        return (!r.isError, try? JSONValue.parse(r.text), r.text)
    }
}
