import Foundation

/// The one place things wait for the student; everything else just happens. Each row is one decision with a sensible
/// default, and every badge shows `needsLook().count`, so a count never disagrees with the list.
public struct NeedsLookItem: Identifiable, Hashable {
    public enum Kind: String, Hashable, CaseIterable {
        /// A file whose course isn't clear.
        case unfiledFile
        /// A file the sorting rules (and free AI) couldn't place with confidence. It already has a best guess.
        case unsureFile
        /// A deadline found in a syllabus, a calendar or Moodle that waits for a yes.
        case proposedDeadline
        /// An import that would overwrite something the student changed.
        case conflict
        /// Flashcards the old version proposed and nobody approved.
        case oldProposedCards
    }

    public var kind: Kind
    public var objectId: Int?
    public var courseId: Int?
    public var title: String
    public var detail: String
    public var id: String { "\(kind.rawValue):\(objectId ?? 0)" }

    public init(kind: Kind, objectId: Int?, courseId: Int?, title: String, detail: String) {
        self.kind = kind; self.objectId = objectId; self.courseId = courseId; self.title = title; self.detail = detail
    }
}

public extension StudyStore {
    func needsLook() -> [NeedsLookItem] {
        var out: [NeedsLookItem] = []
        let courses = courseMap()
        for m in ((try? db.query("SELECT * FROM materials WHERE course_id IS NULL ORDER BY imported_at DESC, id DESC")) ?? []).map(Material.init) {
            let guess = m.suggestedCourseId.flatMap { courses[$0]?.displayName }
            out.append(NeedsLookItem(kind: .unfiledFile, objectId: m.id, courseId: m.suggestedCourseId, title: m.title,
                                     detail: guess.map { "Which course is this for? Maybe \($0)." } ?? "Which course is this for?"))
        }
        for m in unsureFiles() where m.courseId != nil && !sortingInProgress(m.id) {
            out.append(NeedsLookItem(kind: .unsureFile, objectId: m.id, courseId: m.courseId, title: m.title,
                                     detail: "Looks like \(m.role.label.lowercased()), but it's hard to tell. \(m.sortReason ?? "")"
                                        .trimmingCharacters(in: .whitespaces)))
        }
        for a in assignments(AssignmentFilter(onlyProposed: true)) where !a.dismissed {
            let when = a.dueAt.map { "due " + Self.shortDay($0, tz: timezone) } ?? "with no date yet"
            let from = a.source == "moodle" ? "Moodle" : a.source == "ics" ? "your calendar" : "a syllabus"
            out.append(NeedsLookItem(kind: .proposedDeadline, objectId: a.id, courseId: a.courseId, title: a.title,
                                     detail: "Found in \(from), \(when). Add it to your deadlines?"))
        }
        for c in conflicts() {
            out.append(NeedsLookItem(kind: .conflict, objectId: c.id, courseId: nil, title: c.summary,
                                     detail: "An update would change something you edited. Keep yours or take the new one?"))
        }
        let cards = proposedCardCount()
        if cards > 0 {
            out.append(NeedsLookItem(kind: .oldProposedCards, objectId: nil, courseId: nil,
                                     title: "\(cards) suggested flashcard\(cards == 1 ? "" : "s") from before the update",
                                     detail: "Keep them in your reviews, or let them go."))
        }
        return out
    }

    func needsLookCount() -> Int { needsLook().count }

    /// "Fri 16 Oct".
    static func shortDay(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    /// True while a free-AI sort for this file is queued or running, so the student isn't asked about it yet.
    func sortingInProgress(_ materialId: Int) -> Bool { hasSortJob(for: materialId, states: ["queued", "running"]) }

    /// Free AI already finished a sort with this file in it. A file it left unsure goes to the student instead of back
    /// to the AI.
    func sortTried(_ materialId: Int) -> Bool { hasSortJob(for: materialId, states: ["done"]) }

    private func hasSortJob(for materialId: Int, states: [String]) -> Bool {
        // The batch is one string, "12,34,56": the id has to match a whole entry.
        let params: [Any?] = states + ["%,\(materialId),%"]
        return ((try? db.scalarInt("""
            SELECT count(*) FROM claude_jobs WHERE task = 'sort_files' AND state IN (\(states.map { _ in "?" }.joined(separator: ",")))
              AND ',' || COALESCE(json_extract(args_json, '$.material_ids'), '') || ',' LIKE ?
            """, params)) ?? 0) > 0
    }

    /// Keeps or drops every card the old version proposed (one Needs a look row).
    func resolveOldProposedCards(keep: Bool) throws {
        if keep {
            try db.execute("UPDATE cards SET status = 'active', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE status = 'proposed'")
        } else {
            try db.execute("DELETE FROM cards WHERE status = 'proposed'")
        }
        audit(keep ? "keep_proposed_cards" : "drop_proposed_cards")
    }
}
