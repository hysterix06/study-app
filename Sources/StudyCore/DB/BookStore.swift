import Foundation

/// The app's one database (`book.db`): courses from Moodle, their files as text, deadlines, and each course's book
/// with its chapters and flashcards. Moodle and the AI own almost everything here, so there are no user edits to
/// protect and no conflicts: a sync simply makes the rows match what Moodle says.
public final class BookStore: @unchecked Sendable {
    public let db: Database
    public let paths: AppPaths

    public static let schemaVersion = 1

    init(db: Database, paths: AppPaths) throws {
        self.db = db
        self.paths = paths
        try migrate()
    }

    public static func open(paths: AppPaths = AppPaths()) throws -> BookStore {
        paths.ensureFolders()
        return try BookStore(db: Database(path: paths.database.path), paths: paths)
    }

    /// A database in memory, for tests.
    public static func inMemory() throws -> BookStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString)")
        return try BookStore(db: Database(path: ":memory:"), paths: AppPaths(database: root.appendingPathComponent("book.db"), root: root))
    }

    func migrate() throws {
        let version = try db.scalarInt("PRAGMA user_version")
        guard version < Self.schemaVersion else { return }
        try db.transaction {
            if version < 1 { try db.executeScript(Self.v1) }
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    static let v1 = """
    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

    CREATE TABLE courses (
      id INTEGER PRIMARY KEY,
      moodle_id INTEGER UNIQUE,
      code TEXT,
      name TEXT NOT NULL,
      color INTEGER NOT NULL DEFAULT 0,
      starts_on TEXT,
      ends_on TEXT,
      hidden INTEGER NOT NULL DEFAULT 0,
      files_synced_at TEXT,
      book_title TEXT,
      book_lang TEXT,
      is_course INTEGER,
      toc_status TEXT NOT NULL DEFAULT 'none' CHECK (toc_status IN ('none', 'queued', 'writing', 'ready', 'failed')),
      toc_error TEXT,
      toc_attempts INTEGER NOT NULL DEFAULT 0,
      toc_model TEXT,
      toc_tokens_in INTEGER,
      toc_tokens_out INTEGER,
      toc_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE files (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      moodle_uid TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      section TEXT,
      module TEXT,
      position INTEGER NOT NULL DEFAULT 0,
      kind TEXT NOT NULL CHECK (kind IN ('syllabus', 'lecture', 'other')),
      week INTEGER,
      modified_at INTEGER NOT NULL DEFAULT 0,
      size INTEGER NOT NULL DEFAULT 0,
      text TEXT NOT NULL DEFAULT '',
      headings TEXT NOT NULL DEFAULT '[]',
      error TEXT,
      read_at TEXT
    );
    CREATE INDEX files_course ON files(course_id, position);

    CREATE TABLE deadlines (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      moodle_uid TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'assignment',
      due_at TEXT,
      url TEXT,
      submitted INTEGER NOT NULL DEFAULT 0,
      ek_event_id TEXT,
      ek_fingerprint TEXT,
      seen_at TEXT NOT NULL
    );
    CREATE INDEX deadlines_due ON deadlines(due_at);

    CREATE TABLE chapters (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      title TEXT NOT NULL,
      summary TEXT NOT NULL DEFAULT '',
      syllabus_ref TEXT,
      week INTEGER,
      file_ids TEXT NOT NULL DEFAULT '[]',
      status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'writing', 'ready', 'failed')),
      attempts INTEGER NOT NULL DEFAULT 0,
      error TEXT,
      markdown TEXT,
      words INTEGER NOT NULL DEFAULT 0,
      engine TEXT,
      model TEXT,
      tokens_in INTEGER,
      tokens_out INTEGER,
      gen_ms INTEGER,
      generated_at TEXT,
      read_pos TEXT,
      opened_at TEXT,
      read_at TEXT,
      UNIQUE (course_id, position)
    );

    CREATE TABLE cards (
      id INTEGER PRIMARY KEY,
      chapter_id INTEGER NOT NULL REFERENCES chapters(id) ON DELETE CASCADE,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL,
      front TEXT NOT NULL,
      back TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 0,
      due_at TEXT,
      fsrs TEXT
    );
    CREATE INDEX cards_due ON cards(active, due_at);

    CREATE TABLE reviews (
      id INTEGER PRIMARY KEY,
      card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
      reviewed_at TEXT NOT NULL,
      rating INTEGER NOT NULL CHECK (rating IN (1, 3)),
      elapsed_days REAL,
      duration_ms INTEGER
    );
    """

    // MARK: Settings

    public func setting(_ key: String) -> String? { try? db.scalarString("SELECT value FROM settings WHERE key = ?", [key]) }

    public func setSetting(_ key: String, _ value: String?) {
        if let value { _ = try? db.execute("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value]) }
        else { _ = try? db.execute("DELETE FROM settings WHERE key = ?", [key]) }
    }
}

// MARK: - Courses

public struct Course: Identifiable, Hashable, Sendable {
    public var id: Int
    public var moodleId: Int?
    public var code: String?
    public var name: String
    public var color: Int
    public var startsOn: Date?
    public var endsOn: Date?
    public var hidden: Bool
    public var bookTitle: String?
    public var bookLanguage: String?
    /// False when the table of contents found this isn't a taught course.
    public var isCourse: Bool?
    /// none, queued, writing, ready or failed.
    public var tocStatus: String
    public var tocError: String?
    public var filesSyncedAt: Date?

    /// What the app calls the course: its book's title once there is one, else Moodle's name.
    public var title: String { bookTitle ?? name }

    init(row r: Row) {
        id = r.i("id"); moodleId = r.int("moodle_id"); code = r.string("code"); name = r.str("name"); color = r.i("color")
        startsOn = r.string("starts_on").flatMap { ISO.parse($0) }; endsOn = r.string("ends_on").flatMap { ISO.parse($0) }
        hidden = r.bool("hidden"); bookTitle = r.string("book_title"); bookLanguage = r.string("book_lang")
        isCourse = r.int("is_course").map { $0 != 0 }; tocStatus = r.str("toc_status"); tocError = r.string("toc_error")
        filesSyncedAt = r.string("files_synced_at").flatMap { ISO.parse($0) }
    }
}

extension BookStore {
    public func courses(includeHidden: Bool = false) -> [Course] {
        let sql = "SELECT * FROM courses" + (includeHidden ? "" : " WHERE hidden = 0") + " ORDER BY name COLLATE NOCASE"
        return ((try? db.query(sql)) ?? []).map(Course.init(row:))
    }

    public func course(_ id: Int) -> Course? { (try? db.first("SELECT * FROM courses WHERE id = ?", [id])).flatMap { $0.map(Course.init(row:)) } }

    public func course(moodleId: Int) -> Course? {
        (try? db.first("SELECT * FROM courses WHERE moodle_id = ?", [moodleId])).flatMap { $0.map(Course.init(row:)) }
    }

    /// Adds a Moodle course, or refreshes its dates. Name, code and colour are set once: the colour so a course keeps
    /// it, the name so the book's title can take over later.
    @discardableResult
    public func upsertMoodleCourse(moodleId: Int, name: String, code: String?, start: Date?, end: Date?, hidden: Bool) throws -> (id: Int, created: Bool) {
        if let existing = course(moodleId: moodleId) {
            try db.execute("UPDATE courses SET starts_on = ?, ends_on = ? WHERE id = ?", [start, end, existing.id])
            return (existing.id, false)
        }
        let color = try db.scalarInt("SELECT count(*) FROM courses") % CoursePalette.colors.count
        let r = try db.execute("INSERT INTO courses(moodle_id, code, name, color, starts_on, ends_on, hidden) VALUES(?,?,?,?,?,?,?)",
                               [moodleId, code, name, color, start, end, hidden])
        return (r.lastInsertId, true)
    }

    public func setHidden(_ courseId: Int, _ hidden: Bool) {
        _ = try? db.execute("UPDATE courses SET hidden = ? WHERE id = ?", [hidden, courseId])
    }
}

// MARK: - Deadlines

public struct Deadline: Identifiable, Hashable, Sendable {
    public var id: Int
    public var courseId: Int
    public var moodleUid: String
    public var title: String
    public var kind: String
    public var dueAt: Date?
    public var url: String?
    public var submitted: Bool

    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); moodleUid = r.str("moodle_uid"); title = r.str("title"); kind = r.str("kind")
        dueAt = r.string("due_at").flatMap { ISO.parse($0) }; url = r.string("url"); submitted = r.bool("submitted")
    }
}

extension BookStore {
    public enum Change: Equatable { case added, changed, same }

    @discardableResult
    public func upsertDeadline(courseId: Int, uid: String, title: String, kind: String, due: Date?, url: String?, submitted: Bool, now: Date = Date()) throws -> Change {
        let dueText = due.map { ISO.instant($0) }
        if let row = try db.first("SELECT * FROM deadlines WHERE moodle_uid = ?", [uid]) {
            let old = Deadline(row: row)
            let same = old.courseId == courseId && old.title == title && old.kind == kind && row.string("due_at") == dueText
                && old.url == url && old.submitted == submitted
            try db.execute("""
                UPDATE deadlines SET course_id = ?, title = ?, kind = ?, due_at = ?, url = ?, submitted = ?, seen_at = ? WHERE id = ?
                """, [courseId, title, kind, dueText, url, submitted, now, old.id])
            return same ? .same : .changed
        }
        try db.execute("INSERT INTO deadlines(course_id, moodle_uid, title, kind, due_at, url, submitted, seen_at) VALUES(?,?,?,?,?,?,?,?)",
                       [courseId, uid, title, kind, dueText, url, submitted, now])
        return .added
    }

    /// Deadlines Moodle no longer lists for these courses. Returns how many went.
    @discardableResult
    public func removeDeadlines(courseIds: [Int], keeping uids: Set<String>) throws -> Int {
        guard !courseIds.isEmpty else { return 0 }
        let rows = try db.query("SELECT id, moodle_uid FROM deadlines WHERE course_id IN (\(courseIds.map(String.init).joined(separator: ",")))")
        let gone = rows.filter { !uids.contains($0.str("moodle_uid")) }.map { $0.i("id") }
        for id in gone { try db.execute("DELETE FROM deadlines WHERE id = ?", [id]) }
        return gone.count
    }

    /// What's due: work not yet submitted, from two weeks overdue up to `days` ahead, in visible courses.
    public func upcomingDeadlines(now: Date = Date(), days: Int = 7) -> [Deadline] {
        let rows = (try? db.query("""
            SELECT d.* FROM deadlines d JOIN courses c ON c.id = d.course_id
            WHERE c.hidden = 0 AND d.submitted = 0 AND d.due_at IS NOT NULL AND d.due_at >= ? AND d.due_at <= ?
            ORDER BY d.due_at
            """, [now.addingTimeInterval(-14 * 86_400), now.addingTimeInterval(Double(days) * 86_400)])) ?? []
        return rows.map(Deadline.init(row:))
    }

    public func deadlines(courseId: Int) -> [Deadline] {
        ((try? db.query("SELECT * FROM deadlines WHERE course_id = ? ORDER BY due_at IS NULL, due_at", [courseId])) ?? []).map(Deadline.init(row:))
    }
}

// MARK: - Files

public struct CourseFile: Identifiable, Hashable, Sendable {
    public var id: Int
    public var courseId: Int
    public var moodleUid: String
    public var name: String
    public var section: String?
    public var module: String?
    public var position: Int
    public var kind: String
    public var week: Int?
    public var text: String
    public var headings: [String]
    public var error: String?

    /// The name a person would use: Moodle's activity name when there is one, else the file name.
    public var title: String { module ?? name }

    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); moodleUid = r.str("moodle_uid"); name = r.str("name"); section = r.string("section")
        module = r.string("module"); position = r.i("position"); kind = r.str("kind"); week = r.int("week"); text = r.str("text")
        headings = JSON.stringArray(r.string("headings")); error = r.string("error")
    }
}

extension BookStore {
    public func files(courseId: Int) -> [CourseFile] {
        ((try? db.query("SELECT * FROM files WHERE course_id = ? ORDER BY position", [courseId])) ?? []).map(CourseFile.init(row:))
    }

    /// The version of a file already read: Moodle's modified time and size.
    public func fileStamp(_ uid: String) -> (modified: Int, size: Int)? {
        guard let r = try? db.first("SELECT modified_at, size FROM files WHERE moodle_uid = ?", [uid]) else { return nil }
        return (r.i("modified_at"), r.i("size"))
    }

    /// Where a file sits may change without the file changing (a section renamed, an activity moved).
    public func placeFile(_ uid: String, section: String?, module: String?, position: Int) {
        _ = try? db.execute("UPDATE files SET section = ?, module = ?, position = ? WHERE moodle_uid = ?", [section, module, position, uid])
    }

    public func upsertFile(courseId: Int, uid: String, name: String, section: String?, module: String?, position: Int, kind: String, week: Int?,
                           modified: Int, size: Int, text: String, headings: [String], error: String?, now: Date = Date()) throws {
        try db.execute("""
            INSERT INTO files(course_id, moodle_uid, name, section, module, position, kind, week, modified_at, size, text, headings, error, read_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(moodle_uid) DO UPDATE SET course_id = excluded.course_id, name = excluded.name, section = excluded.section,
              module = excluded.module, position = excluded.position, kind = excluded.kind, week = excluded.week,
              modified_at = excluded.modified_at, size = excluded.size, text = excluded.text, headings = excluded.headings,
              error = excluded.error, read_at = excluded.read_at
            """, [courseId, uid, name, section, module, position, kind, week, modified, size, text, JSON.string(headings), error, now])
    }

    @discardableResult
    public func removeFiles(courseId: Int, keeping uids: Set<String>) throws -> Int {
        let rows = try db.query("SELECT id, moodle_uid FROM files WHERE course_id = ?", [courseId])
        let gone = rows.filter { !uids.contains($0.str("moodle_uid")) }.map { $0.i("id") }
        for id in gone { try db.execute("DELETE FROM files WHERE id = ?", [id]) }
        return gone.count
    }

    public func markFilesSynced(_ courseId: Int, now: Date = Date()) {
        _ = try? db.execute("UPDATE courses SET files_synced_at = ? WHERE id = ?", [now, courseId])
    }
}
