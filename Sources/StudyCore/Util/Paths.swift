import Foundation

/// Where the app keeps its data: one database and its daily backups, outside any synced folder (SQLite and file
/// sync corrupt each other). The old app's `study.db` sits in the same folder and is never opened.
/// STUDY_ROOT and STUDY_DB_PATH move everything elsewhere, for tests and screenshots.
public struct AppPaths {
    public let database: URL
    public let root: URL

    public init(database: URL? = nil, root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StudyTracker")
        if let root { self.root = root }
        else if let env = environment["STUDY_ROOT"], !env.isEmpty { self.root = URL(fileURLWithPath: (env as NSString).expandingTildeInPath) }
        else { self.root = support }
        if let database { self.database = database }
        else if let env = environment["STUDY_DB_PATH"], !env.isEmpty { self.database = URL(fileURLWithPath: (env as NSString).expandingTildeInPath) }
        else { self.database = self.root.appendingPathComponent("book.db") }
    }

    public var backups: URL { root.appendingPathComponent("Backups") }

    public func ensureFolders() {
        for u in [root, backups] { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    }
}
