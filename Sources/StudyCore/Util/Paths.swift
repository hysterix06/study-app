import Foundation

/// File locations (§3.3). The database lives outside any synced folder; user files live in ~/StudyTracker.
public struct AppPaths {
    public let database: URL
    public let root: URL

    public init(database: URL? = nil, root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let database { self.database = database }
        else if let env = environment["STUDY_DB_PATH"], !env.isEmpty { self.database = URL(fileURLWithPath: (env as NSString).expandingTildeInPath) }
        else { self.database = home.appendingPathComponent("Library/Application Support/StudyTracker/study.db") }
        if let root { self.root = root }
        else if let env = environment["STUDY_ROOT"], !env.isEmpty { self.root = URL(fileURLWithPath: (env as NSString).expandingTildeInPath) }
        else { self.root = home.appendingPathComponent("StudyTracker") }
    }

    public var inbox: URL { root.appendingPathComponent("Inbox") }
    public var library: URL { root.appendingPathComponent("Library") }
    public var backups: URL { root.appendingPathComponent("Backups") }
    public var export: URL { root.appendingPathComponent("Export") }
    public var captures: URL { root.appendingPathComponent("Captures") }
    public var mcpLog: URL { root.appendingPathComponent("mcp.log") }

    public func ensureFolders() {
        for u in [inbox, library, backups, export, captures] {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
    }

    /// Stored paths are relative to `root` so the folder can be moved.
    public func relative(_ url: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        return p
    }

    public func absolute(_ stored: String) -> URL {
        stored.hasPrefix("/") ? URL(fileURLWithPath: stored) : root.appendingPathComponent(stored)
    }
}

public enum Slug {
    public static func make(_ s: String, max: Int = 60) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let collapsed = cleaned.split(separator: " ").joined(separator: " ")
        return String(collapsed.prefix(max)).trimmingCharacters(in: .whitespaces).isEmpty ? "untitled" : String(collapsed.prefix(max))
    }
}
