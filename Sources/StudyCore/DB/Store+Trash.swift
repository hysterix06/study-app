import Foundation

/// Recently Deleted (UI remap principle 5: nothing is lost by accident).
///
/// A delete saves every row it is about to remove, following SQLite's own foreign keys (cascaded children, and the
/// links that ON DELETE SET NULL would clear), then deletes as before. Restore puts the rows back exactly. Queries
/// never need a `deleted_at` filter, and a trashed file can be imported again. Material files move into
/// `<root>/.Trash/<id>/` instead of the system Trash so restore is exact. Entries are purged after 30 days.
public struct TrashItem: Identifiable, Hashable {
    public var id: Int
    public var kind: String
    public var entityId: Int?
    public var label: String
    public var deletedAt: Date
    public var batchId: String?
}

/// A column value as JSON.
enum StoredValue: Codable, Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)

    init(_ v: SQLValue) {
        switch v {
        case .null: self = .null
        case .int(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .text(let s): self = .text(s)
        case .blob(let b): self = .blob(b)
        }
    }

    var sql: Any? {
        switch self {
        case .null: return nil
        case .int(let i): return i
        case .double(let d): return d
        case .text(let s): return s
        case .blob(let b): return b
        }
    }

    private enum K: String, CodingKey { case i, d, s, b }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if let i = try c.decodeIfPresent(Int64.self, forKey: .i) { self = .int(i) }
        else if let d = try c.decodeIfPresent(Double.self, forKey: .d) { self = .double(d) }
        else if let s = try c.decodeIfPresent(String.self, forKey: .s) { self = .text(s) }
        else if let b = try c.decodeIfPresent(Data.self, forKey: .b) { self = .blob(b) }
        else { self = .null }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .null: break
        case .int(let i): try c.encode(i, forKey: .i)
        case .double(let d): try c.encode(d, forKey: .d)
        case .text(let s): try c.encode(s, forKey: .s)
        case .blob(let b): try c.encode(b, forKey: .b)
        }
    }
}

struct TrashPayload: Codable {
    /// `deleted` rows are inserted back; the others were only changed and get their old values back.
    struct CapturedRow: Codable { var table: String; var rowid: Int64; var values: [String: StoredValue]; var deleted: Bool }
    /// A link that ON DELETE SET NULL cleared.
    struct ClearedLink: Codable { var table: String; var column: String; var rowid: Int64; var value: StoredValue }
    /// Paths relative to the files root.
    struct MovedFile: Codable { var original: String; var trashed: String }

    var rows: [CapturedRow] = []
    var links: [ClearedLink] = []
    var files: [MovedFile] = []
    /// Settings that did not exist before; restore removes them again.
    var absentSettings: [String] = []
}

/// Records what one trash entry removes or changes. Use it inside `StudyStore.trash(…)`.
public final class TrashRecorder {
    struct ForeignKey { var table: String; var column: String; var parent: String; var parentColumn: String; var onDelete: String }

    let store: StudyStore
    let trashId: Int
    var payload = TrashPayload()
    private var seen = Set<String>()
    private var pendingMoves: [(from: URL, to: URL)] = []
    private lazy var foreignKeys: [ForeignKey] = loadForeignKeys()
    private var db: Database { store.db }

    init(store: StudyStore, trashId: Int) { self.store = store; self.trashId = trashId }

    /// Deletes rows by id, saving them and everything the delete would take with them.
    public func delete(_ table: String, ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        if table == "materials" { snapshotSetting("inbox_skipped_materials") }
        var removed: [(table: String, rowid: Int64)] = []
        try capture(table, column: "id", values: ids.map { .int(Int64($0)) }, removed: &removed)
        // Children first, so NO ACTION references (courses → terms) never block the parent.
        for r in removed.reversed() { try db.execute("DELETE FROM \(r.table) WHERE rowid = ?", [r.rowid]) }
        if table == "materials" {
            let skipped = store.skippedMaterialIds()
            store.setSkippedMaterialIds(skipped.subtracting(ids))
        }
    }

    /// Saves rows that are about to change (not be deleted), so restore puts their old values back.
    public func snapshot(_ table: String, ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        let rows = try db.query("SELECT rowid AS __rowid, * FROM \(table) WHERE id IN (\(placeholders(ids.count)))", ids.map { $0 as Any? })
        for r in rows { add(table, r, deleted: false) }
    }

    /// Saves a setting that is about to change.
    public func snapshotSetting(_ key: String) {
        guard !seen.contains("settings#\(key)") else { return }
        seen.insert("settings#\(key)")
        if let r = try? db.first("SELECT rowid AS __rowid, * FROM settings WHERE key = ?", [key]) {
            var values = r.allValues.mapValues(StoredValue.init)
            values.removeValue(forKey: "__rowid")
            payload.rows.append(.init(table: "settings", rowid: rowid(r), values: values, deleted: false))
        } else {
            payload.absentSettings.append(key)
        }
    }

    // MARK: Capture

    private func capture(_ table: String, column: String, values: [SQLValue], removed: inout [(table: String, rowid: Int64)]) throws {
        guard !values.isEmpty else { return }
        let rows = try db.query("SELECT rowid AS __rowid, * FROM \(table) WHERE \(column) IN (\(placeholders(values.count)))", values.map { $0 as Any? })
        let fresh = rows.filter { add(table, $0, deleted: true) }
        for r in fresh { removed.append((table, rowid(r))) }
        if table == "materials" { for r in fresh { planFileMoves(r) } }
        for fk in foreignKeys where fk.parent == table {
            let keys = fresh.map { $0[fk.parentColumn] }.filter { $0 != .null }
            guard !keys.isEmpty else { continue }
            switch fk.onDelete {
            case "SET NULL":
                let refs = try db.query("SELECT rowid AS __rowid, \(fk.column) AS v FROM \(fk.table) WHERE \(fk.column) IN (\(placeholders(keys.count)))",
                                        keys.map { $0 as Any? })
                for r in refs { payload.links.append(.init(table: fk.table, column: fk.column, rowid: rowid(r), value: StoredValue(r["v"]))) }
            case "SET DEFAULT":
                continue
            default: // CASCADE, and NO ACTION / RESTRICT: those children go too.
                try capture(fk.table, column: fk.column, values: keys, removed: &removed)
            }
        }
    }

    /// Adds a row once; returns false if it was already captured.
    @discardableResult
    private func add(_ table: String, _ r: Row, deleted: Bool) -> Bool {
        let id = rowid(r)
        guard seen.insert("\(table)#\(id)").inserted else { return false }
        var values = r.allValues.mapValues(StoredValue.init)
        values.removeValue(forKey: "__rowid")
        payload.rows.append(.init(table: table, rowid: id, values: values, deleted: deleted))
        return true
    }

    private func rowid(_ r: Row) -> Int64 { if case .int(let i) = r["__rowid"] { return i }; return 0 }

    private func planFileMoves(_ r: Row) {
        let folder = store.paths.root.appendingPathComponent(".Trash/\(trashId)")
        for key in ["stored_path", "assets_path"] {
            guard let rel = r.string(key), !rel.isEmpty else { continue }
            let from = store.paths.absolute(rel)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            let to = folder.appendingPathComponent("\(payload.files.count)-\(from.lastPathComponent)")
            pendingMoves.append((from, to))
            payload.files.append(.init(original: rel, trashed: store.paths.relative(to)))
        }
    }

    /// Runs after the database commit, so a rolled-back delete never moves files.
    func moveFiles() {
        let fm = FileManager.default
        for m in pendingMoves {
            try? fm.createDirectory(at: m.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: m.from, to: m.to)
        }
    }

    private func loadForeignKeys() -> [ForeignKey] { TrashRecorder.foreignKeys(db) }

    static func foreignKeys(_ db: Database) -> [ForeignKey] {
        let tables = ((try? db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) ?? []).map { $0.str("name") }
        return tables.flatMap { t in
            ((try? db.query("SELECT \"from\" AS c, \"table\" AS p, \"to\" AS pc, on_delete AS od FROM pragma_foreign_key_list(?)", [t])) ?? []).map {
                ForeignKey(table: t, column: $0.str("c"), parent: $0.str("p"), parentColumn: $0.string("pc") ?? "id", onDelete: $0.str("od").uppercased())
            }
        }
    }

    private func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
}

public extension StudyStore {
    static let trashRetentionDays = 30

    /// Records one Recently Deleted entry. `body` deletes or changes rows through the recorder.
    @discardableResult
    func trash(kind: String, entityId: Int? = nil, label: String, batchId: String? = nil, _ body: (TrashRecorder) throws -> Void) throws -> Int {
        var recorder: TrashRecorder!
        try db.transaction {
            let id = try db.execute("INSERT INTO trash(kind, entity_id, label, payload_json, batch_id) VALUES(?,?,?,'{}',?)",
                                    [kind, entityId, label, batchId]).lastInsertId
            recorder = TrashRecorder(store: self, trashId: id)
            try body(recorder)
            let json = String(decoding: try JSONEncoder().encode(recorder.payload), as: UTF8.self)
            try db.execute("UPDATE trash SET payload_json = ? WHERE id = ?", [json, id])
            audit("trash_\(kind)", entity: kind, id: entityId, detail: label)
        }
        recorder.moveFiles()
        return recorder.trashId
    }

    /// Recently Deleted. Entries of kind `change` only back an Undo (a skip, a dismissal) and are not listed.
    func trashItems() -> [TrashItem] {
        ((try? db.query("SELECT id, kind, entity_id, label, deleted_at, batch_id FROM trash WHERE kind != 'change' ORDER BY id DESC")) ?? []).map {
            TrashItem(id: $0.i("id"), kind: $0.str("kind"), entityId: $0.int("entity_id"), label: $0.str("label"),
                      deletedAt: ISO.parse($0.str("deleted_at")) ?? Date(), batchId: $0.string("batch_id"))
        }
    }

    /// Puts back every row and file of an entry, then removes the entry.
    func restoreTrash(_ id: Int) throws {
        guard let row = try db.first("SELECT payload_json, label FROM trash WHERE id = ?", [id]) else {
            throw StoreError.notFound("That item is no longer in Recently Deleted.")
        }
        let payload = try JSONDecoder().decode(TrashPayload.self, from: Data(row.str("payload_json").utf8))
        do {
            try db.transaction {
                // Rows go back in capture order; checking foreign keys at commit lets children precede parents.
                try db.execute("PRAGMA defer_foreign_keys = ON")
                // SQLite reuses the highest id after a delete, so a restored row whose id was taken since gets a new
                // id, and every restored reference to it follows.
                let fks = TrashRecorder.foreignKeys(db)
                var remap: [String: [Int64: Int64]] = [:]
                func remapped(_ table: String, _ column: String, _ v: StoredValue) -> StoredValue {
                    guard case .int(let old) = v, let fk = fks.first(where: { $0.table == table && $0.column == column }),
                          let new = remap[fk.parent]?[old] else { return v }
                    return .int(new)
                }
                for var r in payload.rows {
                    for (c, v) in r.values { r.values[c] = remapped(r.table, c, v) }
                    if let new = try putBack(r), new != r.rowid { remap[r.table, default: [:]][r.rowid] = new }
                }
                for l in payload.links {
                    let rowid = remap[l.table]?[l.rowid] ?? l.rowid
                    try db.execute("UPDATE \(l.table) SET \(l.column) = ? WHERE rowid = ?", [remapped(l.table, l.column, l.value).sql, rowid])
                }
                for key in payload.absentSettings { try db.execute("DELETE FROM settings WHERE key = ?", [key]) }
                try db.execute("DELETE FROM trash WHERE id = ?", [id])
                audit("restore", entity: "trash", id: id, detail: row.str("label"))
            }
        } catch let e as DBError {
            if "\(e)".contains("UNIQUE") {
                throw StoreError.inUse("\(row.str("label")) can't be restored because a copy of it was added again.")
            }
            throw e
        }
        let fm = FileManager.default
        for f in payload.files {
            let from = paths.absolute(f.trashed), to = paths.absolute(f.original)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: from, to: to)
        }
        try? fm.removeItem(at: trashFolder(id))
    }

    /// Delete now: the rows are already gone; this drops the saved copy and its files.
    func deleteTrashNow(_ id: Int) throws {
        try db.execute("DELETE FROM trash WHERE id = ?", [id])
        try? FileManager.default.removeItem(at: trashFolder(id))
    }

    /// Removes entries older than the retention period. Returns how many were purged.
    @discardableResult
    func purgeTrash(now: Date = Date(), olderThanDays days: Int = StudyStore.trashRetentionDays) -> Int {
        let cutoff = ISO.instant(now.addingTimeInterval(-Double(days) * 86_400))
        let ids = ((try? db.query("SELECT id FROM trash WHERE deleted_at < ?", [cutoff])) ?? []).map { $0.i("id") }
        for id in ids { try? deleteTrashNow(id) }
        return ids.count
    }

    private func trashFolder(_ id: Int) -> URL { paths.root.appendingPathComponent(".Trash/\(id)") }

    /// Returns the row's id after insert (it differs when the old id was taken since).
    private func putBack(_ r: TrashPayload.CapturedRow) throws -> Int64? {
        var cols = r.values.keys.sorted()
        let hasId = r.values["id"] != nil
        if r.table == "settings", case .text(let key)? = r.values["key"] {
            if try db.scalarInt("SELECT count(*) FROM settings WHERE key = ?", [key]) > 0 {
                try db.execute("UPDATE settings SET value = ? WHERE key = ?", [r.values["value"]?.sql, key])
                return nil
            }
        } else if !r.deleted {
            let set = cols.filter { $0 != "id" }
            guard !set.isEmpty else { return nil }
            try db.execute("UPDATE \(r.table) SET \(set.map { "\($0) = ?" }.joined(separator: ", ")) WHERE rowid = ?",
                           set.map { r.values[$0]!.sql } + [r.rowid])
            return nil
        } else if hasId, try db.scalarInt("SELECT count(*) FROM \(r.table) WHERE id = ?", [r.rowid]) > 0 {
            cols.removeAll { $0 == "id" }
        }
        let verb = hasId || r.table == "settings" ? "INSERT" : "INSERT OR IGNORE"
        let id = try db.execute("\(verb) INTO \(r.table)(\(cols.joined(separator: ", "))) VALUES(\(cols.map { _ in "?" }.joined(separator: ",")))",
                                cols.map { r.values[$0]!.sql }).lastInsertId
        return hasId ? Int64(id) : nil
    }

    // MARK: Domain deletes

    /// Deletes one row and everything that belongs to it, as a Recently Deleted entry. Returns the undo for the toast.
    func trashRow(kind: String, table: String, id: Int, label: String) throws -> UndoSnapshot {
        let tid = try trash(kind: kind, entityId: id, label: label) { try $0.delete(table, ids: [id]) }
        return .trash([tid], label: "Deleted \(label)")
    }

    func trashCourse(_ id: Int) throws -> UndoSnapshot {
        try trashRow(kind: "course", table: "courses", id: id, label: course(id)?.displayName ?? "course")
    }

    /// A term takes its courses with it; restore brings them all back.
    func trashTerm(_ id: Int) throws -> UndoSnapshot {
        try trashRow(kind: "term", table: "terms", id: id, label: terms().first { $0.id == id }?.name ?? "term")
    }

    func trashMaterial(_ id: Int) throws -> UndoSnapshot {
        try trashRow(kind: "material", table: "materials", id: id, label: material(id)?.title ?? "file")
    }

    /// Imported assignments keep a tombstone so re-import does not bring them back; the rest go to Recently Deleted.
    func trashAssignment(_ id: Int) throws -> UndoSnapshot? {
        guard let a = assignment(id) else { return nil }
        if a.externalUid != nil { return try deleteAssignment(id) }
        return try trashRow(kind: "assignment", table: "assignments", id: id, label: a.title)
    }

    func trashCard(_ id: Int) throws -> UndoSnapshot {
        try trashRow(kind: "card", table: "cards", id: id, label: "card")
    }

    func trashConcept(_ id: Int) throws -> UndoSnapshot {
        let name = (try? db.scalarString("SELECT name FROM concepts WHERE id = ?", [id])) ?? nil
        return try trashRow(kind: "concept", table: "concepts", id: id, label: name ?? "concept")
    }

    func trashNote(_ id: Int) throws -> UndoSnapshot {
        let title = (try? db.scalarString("SELECT title FROM notes WHERE id = ?", [id])) ?? nil
        return try trashRow(kind: "note", table: "notes", id: id, label: title ?? "note")
    }

    /// Makes a change that deletes nothing undoable: `body` snapshots rows through the recorder before changing them.
    func recordChange(_ label: String, _ body: (TrashRecorder) throws -> Void) throws -> UndoSnapshot {
        .trash([try trash(kind: "change", label: label, body)], label: label)
    }

    func skipMaterialUndoable(_ id: Int) throws -> UndoSnapshot {
        try recordChange("Skipped \(material(id)?.title ?? "file")") { rec in
            rec.snapshotSetting("inbox_skipped_materials")
            skipMaterial(id)
        }
    }

    func dismissProposedUndoable(_ id: Int) throws -> UndoSnapshot {
        try recordChange("Dismissed \(assignment(id)?.title ?? "proposal")") { rec in
            try rec.snapshot("assignments", ids: [id])
            try dismissProposed(id)
        }
    }

    /// Inbox "Clear all" as one Recently Deleted entry: one Undo restores every file, card and decision.
    func clearInbox(deleteMaterials: [Int], skip: [Int], dismissAssignments: [Int], dismissBlocks: [Int], deleteCards: [Int],
                    keepMine conflicts: [Int]) throws -> UndoSnapshot {
        let n = deleteMaterials.count + skip.count + dismissAssignments.count + dismissBlocks.count + deleteCards.count + conflicts.count
        let label = "Cleared the Inbox (\(n) item\(n == 1 ? "" : "s"))"
        let id = try trash(kind: "inbox_batch", label: label, batchId: UUID().uuidString) { rec in
            try rec.delete("materials", ids: deleteMaterials)
            if !skip.isEmpty {
                rec.snapshotSetting("inbox_skipped_materials")
                for m in skip { skipMaterial(m) }
            }
            try rec.snapshot("assignments", ids: dismissAssignments)
            for a in dismissAssignments { try dismissProposed(a) }
            try rec.snapshot("study_blocks", ids: dismissBlocks)
            for b in dismissBlocks { try setBlockStatus(b, "dismissed") }
            try rec.delete("cards", ids: deleteCards)
            try rec.snapshot("conflicts", ids: conflicts)
            for c in conflicts { try resolveConflict(c, acceptIncoming: false) }
        }
        return .trash([id], label: label)
    }
}
