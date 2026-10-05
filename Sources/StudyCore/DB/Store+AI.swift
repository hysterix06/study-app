import Foundation

/// Local records for the AI features: which MCP apps use the server, what each engine request cost, and in-app chats.
/// Nothing here is sent anywhere.
public struct MCPClientRecord: Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var version: String?
    public var protocolVersion: String?
    public var firstSeen: Date
    public var lastSeen: Date
}

public struct AIChat: Identifiable, Hashable {
    public var id: Int
    public var task: AITask?
    public var args: [String: String]
    public var objectKind: String?
    public var objectId: Int?
    public var jobId: Int?
    public var title: String
    public var engine: String
    public var updatedAt: Date
}

public struct AIChatMessage: Identifiable, Hashable {
    public var id: Int
    public var role: String
    public var text: String
    public var dataJson: String?
    public var createdAt: Date
}

public extension StudyStore {
    // MARK: MCP clients

    func recordMCPClient(name: String, version: String?, protocolVersion: String?) {
        _ = try? db.execute("""
            INSERT INTO mcp_clients(name, version, protocol) VALUES(?,?,?)
            ON CONFLICT(name) DO UPDATE SET version = COALESCE(excluded.version, version), protocol = COALESCE(excluded.protocol, protocol),
              last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            """, [name, version, protocolVersion])
    }

    func mcpClients() -> [MCPClientRecord] {
        ((try? db.query("SELECT * FROM mcp_clients ORDER BY last_seen DESC")) ?? []).map { r in
            MCPClientRecord(name: r.str("name"), version: r.string("version"), protocolVersion: r.string("protocol"),
                            firstSeen: ISO.parse(r.str("first_seen")) ?? Date(), lastSeen: ISO.parse(r.str("last_seen")) ?? Date())
        }
    }

    // MARK: Usage

    func recordAIUsage(provider: String, model: String, jobId: Int?, chatId: Int?, tokensIn: Int, tokensOut: Int, costUSD: Double?) {
        _ = try? db.execute("INSERT INTO ai_usage(provider, model, job_id, chat_id, tokens_in, tokens_out, cost_usd) VALUES(?,?,?,?,?,?,?)",
                            [provider, model, jobId, chatId, tokensIn, tokensOut, costUSD])
        if let jobId { addJobUsage(jobId, tokensIn: tokensIn, tokensOut: tokensOut, costUSD: costUSD) }
    }

    /// Money spent on paid engines since the start of this calendar month (local time).
    func aiSpendThisMonth(now: Date = Date()) -> Double {
        let start = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        return (try? db.first("SELECT COALESCE(SUM(cost_usd), 0) AS s FROM ai_usage WHERE at >= ?", [ISO.instant(start)]))??.double("s") ?? 0
    }

    /// Requests made today with a provider, for showing free-tier use ("12 of about 50 today").
    func aiRequestsToday(provider: String, now: Date = Date()) -> Int {
        let start = Calendar.current.startOfDay(for: now)
        return (try? db.scalarInt("SELECT count(*) FROM ai_usage WHERE provider = ? AND at >= ?", [provider, ISO.instant(start)])) ?? 0
    }

    // MARK: Chats

    @discardableResult
    func createChat(task: AITask?, args: [String: String], objectKind: String?, objectId: Int?, jobId: Int?, title: String, engine: String) throws -> Int {
        let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        return try db.execute("INSERT INTO ai_chats(task, args_json, object_kind, object_id, job_id, title, engine) VALUES(?,?,?,?,?,?,?)",
                              [task?.rawValue, json, objectKind, objectId, jobId, title, engine]).lastInsertId
    }

    func chat(_ id: Int) -> AIChat? {
        (try? db.first("SELECT * FROM ai_chats WHERE id = ?", [id])).flatMap { $0.map(Self.chatRow) }
    }

    func chats(limit: Int = 50) -> [AIChat] {
        ((try? db.query("SELECT * FROM ai_chats ORDER BY updated_at DESC, id DESC LIMIT ?", [limit])) ?? []).map(Self.chatRow)
    }

    func chat(forJob jobId: Int) -> AIChat? {
        (try? db.first("SELECT * FROM ai_chats WHERE job_id = ? ORDER BY id DESC LIMIT 1", [jobId])).flatMap { $0.map(Self.chatRow) }
    }

    private static func chatRow(_ r: Row) -> AIChat {
        AIChat(id: r.i("id"), task: r.string("task").flatMap(AITask.init(rawValue:)),
               args: (try? JSONDecoder().decode([String: String].self, from: Data(r.str("args_json").utf8))) ?? [:],
               objectKind: r.string("object_kind"), objectId: r.int("object_id"), jobId: r.int("job_id"),
               title: r.str("title"), engine: r.str("engine"), updatedAt: ISO.parse(r.str("updated_at")) ?? Date())
    }

    @discardableResult
    func appendChatMessage(_ chatId: Int, role: String, text: String, dataJson: String? = nil) throws -> Int {
        let id = try db.execute("INSERT INTO ai_messages(chat_id, role, text, data_json) VALUES(?,?,?,?)", [chatId, role, text, dataJson]).lastInsertId
        try db.execute("UPDATE ai_chats SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?", [chatId])
        return id
    }

    func chatMessages(_ chatId: Int) -> [AIChatMessage] {
        ((try? db.query("SELECT * FROM ai_messages WHERE chat_id = ? ORDER BY id", [chatId])) ?? []).map { r in
            AIChatMessage(id: r.i("id"), role: r.str("role"), text: r.str("text"), dataJson: r.string("data_json"), createdAt: ISO.parse(r.str("created_at")) ?? Date())
        }
    }

    func setChatEngine(_ chatId: Int, engine: String) {
        _ = try? db.execute("UPDATE ai_chats SET engine = ? WHERE id = ?", [engine, chatId])
    }

    /// Chats are the student's own conversations: deleting one removes it completely (it isn't kept in Recently Deleted).
    func deleteChat(_ id: Int) {
        _ = try? db.execute("DELETE FROM ai_messages WHERE chat_id = ?", [id])
        _ = try? db.execute("DELETE FROM ai_chats WHERE id = ?", [id])
    }

    /// Removes chats older than the retention setting (days; 0 keeps them forever).
    func pruneChats(olderThanDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = ISO.instant(now.addingTimeInterval(-Double(days) * 86_400))
        _ = try? db.execute("DELETE FROM ai_messages WHERE chat_id IN (SELECT id FROM ai_chats WHERE updated_at < ?)", [cutoff])
        _ = try? db.execute("DELETE FROM ai_chats WHERE updated_at < ?", [cutoff])
    }
}
