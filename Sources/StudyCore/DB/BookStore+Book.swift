import Foundation

/// One chapter of a course's book: its place in the table of contents and, once written, its Markdown.
public struct Chapter: Identifiable, Hashable, Sendable {
    public var id: Int
    public var courseId: Int
    public var position: Int
    public var title: String
    public var summary: String
    public var syllabusRef: String?
    public var week: Int?
    public var fileIds: [Int]
    /// queued, writing, ready or failed.
    public var status: String
    public var attempts: Int
    public var error: String?
    public var markdown: String?
    public var words: Int
    public var model: String?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var generatedAt: Date?
    public var readPos: String?
    public var readAt: Date?

    public var isReady: Bool { status == "ready" && markdown != nil }

    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); position = r.i("position"); title = r.str("title"); summary = r.str("summary")
        syllabusRef = r.string("syllabus_ref"); week = r.int("week"); fileIds = JSON.intArray(r.string("file_ids")); status = r.str("status")
        attempts = r.i("attempts"); error = r.string("error"); markdown = r.string("markdown"); words = r.i("words"); model = r.string("model")
        tokensIn = r.int("tokens_in"); tokensOut = r.int("tokens_out"); generatedAt = r.string("generated_at").flatMap { ISO.parse($0) }
        readPos = r.string("read_pos"); readAt = r.string("read_at").flatMap { ISO.parse($0) }
    }
}

/// A unit of work for the book writer.
public enum BookJob: Hashable, Sendable {
    case toc(courseId: Int)
    case chapter(id: Int)
}

extension BookStore {
    // MARK: Reading

    public func chapters(courseId: Int) -> [Chapter] {
        ((try? db.query("SELECT * FROM chapters WHERE course_id = ? ORDER BY position", [courseId])) ?? []).map(Chapter.init(row:))
    }

    public func chapter(_ id: Int) -> Chapter? {
        (try? db.first("SELECT * FROM chapters WHERE id = ?", [id])).flatMap { $0.map(Chapter.init(row:)) }
    }

    /// The table of contents as the prompts need it.
    public func bookPlan(courseId: Int) -> BookPlan? {
        guard let c = course(courseId), let title = c.bookTitle else { return nil }
        let chs = chapters(courseId: courseId)
        return BookPlan(isCourse: true, title: title, language: c.bookLanguage ?? "en",
                        chapters: chs.map { BookPlan.Chapter(title: $0.title, summary: $0.summary, syllabusRef: $0.syllabusRef, week: $0.week, files: $0.fileIds) })
    }

    /// What the prompts get from a course's files: the syllabus text, and the lectures and readings (titles, headings
    /// and text, or just titles for files not read yet).
    public func bookInputs(courseId: Int) -> (course: BookPrompts.Course, syllabus: String, files: [BookPrompts.File]) {
        let c = course(courseId)
        let all = files(courseId: courseId)
        let syllabus = all.filter { $0.kind == FileKind.syllabus && !$0.text.isEmpty }.map { "[\($0.title)]\n\($0.text)" }.joined(separator: "\n\n")
        let lectures = all.filter { $0.kind == FileKind.lecture }.map {
            BookPrompts.File(id: $0.id, title: $0.title, section: $0.section, headings: $0.headings, text: $0.text)
        }
        return (BookPrompts.Course(name: c?.name ?? "", code: c?.code), syllabus, lectures)
    }

    /// Week 1 is the week the term started (see `MoodleSync`), when known.
    public func currentWeek(now: Date = Date()) -> Int? {
        guard let start = setting("term_start").flatMap({ ISO.parse($0) }) else { return nil }
        let days = Int(now.timeIntervalSince(start) / 86_400)
        return days < 0 ? nil : days / 7 + 1
    }

    // MARK: What to write next

    /// The next piece of the books to write: the chapter the student opened, then any missing table of contents, then
    /// chapters around where the course is now (this one and the next), then later ones, then earlier ones. Without
    /// teaching weeks, chapters go in order, taking turns between courses. A chapter waits while its files are still
    /// being read, unless the student opened it.
    public func nextJob(now: Date = Date(), focus: Int? = nil, excluding: Set<BookJob> = []) -> BookJob? {
        if let f = focus, let c = chapter(f), c.status == "queued", !excluding.contains(.chapter(id: f)),
           course(c.courseId)?.hidden == false {
            return .chapter(id: f)
        }
        let visible = courses()
        for c in visible where (c.tocStatus == "none" || c.tocStatus == "queued") && !excluding.contains(.toc(courseId: c.id)) && hasBookMaterial(c) {
            return .toc(courseId: c.id)
        }
        let week = currentWeek(now: now)
        var best: (tier: Int, distance: Int, course: Int, id: Int)?
        for c in visible where c.tocStatus == "ready" && c.isCourse != false {
            let chs = chapters(courseId: c.id)
            // This week's chapters (a week can hold more than one) and the next one come first.
            var current: Int?, weekStart = 0
            if let week, chs.contains(where: { $0.week != nil }) {
                let cur = chs.lastIndex { ($0.week ?? .max) <= week } ?? 0
                current = cur
                weekStart = chs.firstIndex { $0.week != nil && $0.week == chs[cur].week } ?? cur
            }
            for (i, ch) in chs.enumerated() where ch.status == "queued" && !excluding.contains(.chapter(id: ch.id)) && filesReady(ch, course: c) {
                let rank: (Int, Int)
                if let cur = current {
                    rank = (weekStart...(cur + 1)).contains(i) ? (0, i - weekStart) : i > cur ? (1, i - cur) : (2, weekStart - i)
                } else {
                    rank = (1, i)
                }
                let candidate = (tier: rank.0, distance: rank.1, course: c.id, id: ch.id)
                if best == nil || (candidate.tier, candidate.distance, candidate.course) < (best!.tier, best!.distance, best!.course) { best = candidate }
            }
        }
        return best.map { .chapter(id: $0.id) }
    }

    /// A table of contents needs the syllabus, or every file listed.
    func hasBookMaterial(_ c: Course) -> Bool {
        if c.filesSyncedAt != nil { return true }
        return ((try? db.scalarInt("SELECT count(*) FROM files WHERE course_id = ? AND kind = 'syllabus' AND text != ''", [c.id])) ?? 0) > 0
    }

    func filesReady(_ ch: Chapter, course c: Course) -> Bool {
        if ch.fileIds.isEmpty || c.filesSyncedAt != nil { return true }
        let ids = ch.fileIds.map(String.init).joined(separator: ",")
        return ((try? db.scalarInt("SELECT count(*) FROM files WHERE id IN (\(ids)) AND text != ''")) ?? 0) > 0
    }

    // MARK: Writing

    public func setTocState(_ courseId: Int, _ status: String, error: String? = nil, countAttempt: Bool = false) {
        _ = try? db.execute("UPDATE courses SET toc_status = ?, toc_error = ?, toc_attempts = toc_attempts + ? WHERE id = ?",
                            [status, error, countAttempt ? 1 : 0, courseId])
    }

    public func setChapterState(_ id: Int, _ status: String, error: String? = nil, countAttempt: Bool = false) {
        _ = try? db.execute("UPDATE chapters SET status = ?, error = ?, attempts = attempts + ? WHERE id = ?", [status, error, countAttempt ? 1 : 0, id])
    }

    /// Saves a course's table of contents. A page that isn't a taught course is hidden instead.
    public func saveBook(courseId: Int, plan: BookPlan, model: String, usage: (input: Int, output: Int), now: Date = Date()) throws {
        try db.transaction {
            try db.execute("""
                UPDATE courses SET book_title = ?, book_lang = ?, is_course = ?, toc_status = 'ready', toc_error = NULL, toc_model = ?,
                  toc_tokens_in = ?, toc_tokens_out = ?, toc_at = ?, hidden = CASE WHEN ? THEN 1 ELSE hidden END WHERE id = ?
                """, [plan.isCourse ? plan.title : nil, plan.language, plan.isCourse, model, usage.input, usage.output, now, !plan.isCourse, courseId])
            guard plan.isCourse, try db.scalarInt("SELECT count(*) FROM chapters WHERE course_id = ?", [courseId]) == 0 else { return }
            for (i, c) in plan.chapters.enumerated() {
                try db.execute("INSERT INTO chapters(course_id, position, title, summary, syllabus_ref, week, file_ids) VALUES(?,?,?,?,?,?,?)",
                               [courseId, i + 1, c.title, c.summary, c.syllabusRef, c.week, JSON.string(c.files)])
            }
        }
    }

    /// Saves a written chapter and its flashcards (not yet in review: they join when the chapter is read). Rewriting a
    /// chapter keeps the cards already reviewed.
    public func saveChapter(_ id: Int, markdown: String, doc: ChapterDoc, engine: String, model: String, usage: (input: Int, output: Int),
                            milliseconds: Int, now: Date = Date()) throws {
        guard let ch = chapter(id) else { return }
        try db.transaction {
            try db.execute("""
                UPDATE chapters SET status = 'ready', error = NULL, markdown = ?, words = ?, engine = ?, model = ?, tokens_in = ?, tokens_out = ?,
                  gen_ms = ?, generated_at = ? WHERE id = ?
                """, [markdown, doc.words, engine, model, usage.input, usage.output, milliseconds, now, id])
            try db.execute("DELETE FROM cards WHERE chapter_id = ? AND id NOT IN (SELECT card_id FROM reviews)", [id])
            let kept = Set(try db.query("SELECT front FROM cards WHERE chapter_id = ?", [id]).map { $0.str("front") })
            let active = ch.readAt != nil
            for (i, card) in doc.cards.enumerated() where !kept.contains(card.q) {
                try db.execute("INSERT INTO cards(chapter_id, course_id, ordinal, front, back, active, due_at) VALUES(?,?,?,?,?,?,?)",
                               [id, ch.courseId, i, card.q, card.a, active, active ? now : nil])
            }
        }
    }

    /// Anything left mid-write when the app quit goes back in the queue.
    public func resetInterrupted() {
        _ = try? db.execute("UPDATE chapters SET status = 'queued' WHERE status = 'writing'")
        _ = try? db.execute("UPDATE courses SET toc_status = 'queued' WHERE toc_status = 'writing'")
    }

    /// "Try again" on a chapter or a table of contents that failed twice.
    public func retry(_ job: BookJob) {
        switch job {
        case .chapter(let id): _ = try? db.execute("UPDATE chapters SET status = 'queued', attempts = 0, error = NULL WHERE id = ?", [id])
        case .toc(let c): _ = try? db.execute("UPDATE courses SET toc_status = 'queued', toc_attempts = 0, toc_error = NULL WHERE id = ?", [c])
        }
    }

    // MARK: Reading progress

    public func saveReadPosition(_ id: Int, section: Int, fraction: Double) {
        _ = try? db.execute("UPDATE chapters SET read_pos = ?, opened_at = COALESCE(opened_at, ?) WHERE id = ?",
                            [JSON.string(["section": section, "fraction": fraction]), Date(), id])
    }

    /// The student reached the end: the chapter counts as read and its flashcards join review.
    public func markRead(_ id: Int, now: Date = Date()) {
        _ = try? db.transaction {
            try db.execute("UPDATE chapters SET read_at = COALESCE(read_at, ?) WHERE id = ?", [now, id])
            try db.execute("UPDATE cards SET active = 1, due_at = COALESCE(due_at, ?) WHERE chapter_id = ? AND active = 0", [now, id])
        }
    }
}
