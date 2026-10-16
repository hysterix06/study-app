import Foundation

/// A flashcard from a chapter. It joins review once the chapter has been read.
public struct Card: Identifiable, Hashable, Sendable {
    public var id: Int
    public var chapterId: Int
    public var courseId: Int
    public var front: String
    public var back: String
    public var dueAt: Date?
    public var fsrs: FSRSCard
    public var chapterTitle: String?
    public var chapterPosition: Int?

    init(row r: Row) {
        id = r.i("id"); chapterId = r.i("chapter_id"); courseId = r.i("course_id"); front = r.str("front"); back = r.str("back")
        dueAt = r.string("due_at").flatMap { ISO.parse($0) }; fsrs = FSRSCard.decode(r.string("fsrs")) ?? FSRSCard()
        chapterTitle = r.string("chapter_title"); chapterPosition = r.int("chapter_position")
    }

    /// Card text as plain text: maths delimiters, if the model used them anyway, are dropped.
    public static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: #"\\[()\[\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension BookStore {
    /// Two answers only: Forgot is FSRS's Again and Got it is its Good. A card got the first time goes straight to a
    /// few days out, since it comes from a chapter just read.
    static let scheduler = FSRS(learningSteps: false)

    private static let dueSQL = """
        FROM cards c JOIN chapters ch ON ch.id = c.chapter_id JOIN courses co ON co.id = c.course_id
        WHERE c.active = 1 AND co.hidden = 0 AND c.due_at <= ?
        """

    /// Cards to review now, oldest due first, then in book order. Hidden courses' cards wait.
    public func dueCards(now: Date = Date()) -> [Card] {
        let sql = "SELECT c.*, ch.title AS chapter_title, ch.position AS chapter_position \(Self.dueSQL) ORDER BY c.due_at, c.course_id, ch.position, c.ordinal"
        return ((try? db.query(sql, [now])) ?? []).map(Card.init(row:))
    }

    public func dueCount(now: Date = Date()) -> Int {
        (try? db.scalarInt("SELECT count(*) \(Self.dueSQL)", [now])) ?? 0
    }

    /// When the next card comes due, after `now`.
    public func nextDue(after now: Date = Date()) -> Date? {
        let sql = "SELECT min(c.due_at) FROM cards c JOIN courses co ON co.id = c.course_id WHERE c.active = 1 AND co.hidden = 0 AND c.due_at > ?"
        return (try? db.scalarString(sql, [now])).flatMap { $0 }.flatMap { ISO.parse($0) }
    }

    /// Records Forgot or Got it and schedules the card. Returns the card as it now stands.
    @discardableResult
    public func review(_ cardId: Int, gotIt: Bool, now: Date = Date(), duration: TimeInterval? = nil) -> Card? {
        guard let row = (try? db.first("SELECT * FROM cards WHERE id = ?", [cardId])) ?? nil else { return nil }
        var card = Card(row: row)
        let elapsed = card.fsrs.lastReview.map { max(0, now.timeIntervalSince($0) / 86_400) }
        let result = Self.scheduler.review(card.fsrs, rating: gotIt ? .good : .again, now: now)
        _ = try? db.transaction {
            try db.execute("UPDATE cards SET fsrs = ?, due_at = ? WHERE id = ?", [result.card.encode(), result.due, cardId])
            try db.execute("INSERT INTO reviews(card_id, reviewed_at, rating, elapsed_days, duration_ms) VALUES(?,?,?,?,?)",
                           [cardId, now, gotIt ? 3 : 1, elapsed, duration.map { Int($0 * 1000) }])
        }
        card.fsrs = result.card
        card.dueAt = result.due
        return card
    }
}

/// One sitting of review: the cards due when it starts, and a forgotten card back at the end until it's got.
public struct ReviewSession: Sendable {
    public private(set) var queue: [Card]
    public private(set) var answered = 0
    /// A card due again sooner than this goes back in the queue.
    static let sameSitting: TimeInterval = 20 * 60

    public init(cards: [Card]) { queue = cards }

    public var current: Card? { queue.first }
    public var isDone: Bool { queue.isEmpty }

    public mutating func answer(gotIt: Bool, store: BookStore, now: Date = Date(), duration: TimeInterval? = nil) {
        guard let card = current else { return }
        queue.removeFirst()
        answered += 1
        if let updated = store.review(card.id, gotIt: gotIt, now: now, duration: duration),
           let due = updated.dueAt, due.timeIntervalSince(now) < Self.sameSitting {
            queue.append(updated)
        }
    }
}
