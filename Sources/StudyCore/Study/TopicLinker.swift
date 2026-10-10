import Foundation

/// Connects course files, practice problems and cards to the path's topics by the words they share. It runs without
/// AI, so linking always happens; when free AI is around, its reading of a lecture replaces these guesses.
public enum TopicLinker {
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "that", "this", "what", "how", "why", "are", "was", "its", "their", "your", "you",
        "of", "to", "in", "on", "a", "an", "is", "be", "by", "or", "as", "at", "it", "vs", "intro", "introduction", "part", "chapter",
        "week", "lecture", "session", "slides", "notes", "topic", "unit", "module", "les", "des", "der", "die", "das", "und", "el", "la",
        "los", "las", "del", "de", "y", "en", "il", "di", "e", "het", "een", "van",
    ]

    /// Significant words, lowercase and singular: "Pricing strategies" → ["pricing", "strategy"].
    public static func words(_ s: String) -> Set<String> {
        Set(FileSorter.clean(s).split(separator: " ").map { w -> String in
            var w = String(w).trimmingCharacters(in: CharacterSet(charactersIn: "%()[]:."))
            if w.hasSuffix("ies"), w.count > 4 { w = String(w.dropLast(3)) + "y" }
            else if w.hasSuffix("s"), !w.hasSuffix("ss"), w.count > 4 { w = String(w.dropLast()) }
            return w
        }.filter { $0.count >= 3 && !stopwords.contains($0) && Int($0) == nil })
    }

    /// How much two texts share: the share of the topic's words that appear in the text, from 0 to 1.
    public static func overlap(_ text: Set<String>, topic: Set<String>) -> Double {
        guard !topic.isEmpty, !text.isEmpty else { return 0 }
        return Double(text.intersection(topic).count) / Double(min(topic.count, 6))
    }

    /// The topic a text is about, if one clearly fits.
    public static func bestTopic(for text: String, topics: [(id: Int, words: Set<String>)], minimum: Double = 0.5) -> Int? {
        let w = words(text)
        let scored = topics.map { ($0.id, overlap(w, topic: $0.words)) }.filter { $0.1 >= minimum }.sorted { $0.1 > $1.1 }
        guard let top = scored.first else { return nil }
        if scored.count > 1 && scored[1].1 == top.1 { return nil }
        return top.0
    }
}

public extension StudyStore {
    /// A topic's words: its title and the terms on its notebook page.
    func topicWords(courseId: Int) -> [(id: Int, words: Set<String>)] {
        let guides = notebooks(courseId: courseId)
        return topics(courseId: courseId).map { t in
            let terms = guides[t.id]?.terms.map(\.term).joined(separator: " ") ?? ""
            return (t.id, TopicLinker.words(t.title + " " + terms))
        }
    }

    /// Links a lecture, reading or class example to the topics it teaches, slide by slide, unless its coverage is already
    /// known (from the course builder, the free AI or the student). Earlier guesses are made again, since the topics they
    /// pointed at may have changed. Returns how many topics it covers.
    @discardableResult
    func linkCoverageByWords(materialId: Int) -> Int {
        guard let m = material(materialId), let courseId = m.courseId, [.lecture, .reading, .example].contains(m.role), !m.excluded else { return 0 }
        let known = (try? db.scalarInt("""
            SELECT count(*) FROM topic_coverage c JOIN path_topics t ON t.id = c.topic_id
            WHERE c.material_id = ? AND c.source != 'scan' AND t.retired = 0 AND t.course_id = ?
            """, [materialId, courseId])) ?? 0
        guard known == 0 else { return 0 }
        let topics = topicWords(courseId: courseId)
        guard !topics.isEmpty else { return 0 }
        _ = try? db.execute("DELETE FROM topic_coverage WHERE material_id = ? AND source = 'scan'", [materialId])
        var byTopic: [Int: [Int]] = [:]
        for c in chunks(materialId: materialId) {
            let text = [c.heading, String(c.textMd.prefix(400))].compactMap { $0 }.joined(separator: " ")
            if let t = TopicLinker.bestTopic(for: text, topics: topics) { byTopic[t, default: []].append(c.id) }
        }
        // A file that's mostly about one topic, judging by its title, covers at least that one.
        if byTopic.isEmpty, let t = TopicLinker.bestTopic(for: m.title, topics: topics) { byTopic[t] = [] }
        for (topicId, chunkIds) in byTopic {
            _ = try? db.execute("""
                INSERT INTO topic_coverage(topic_id, material_id, chunk_ids_json, source) VALUES(?,?,?,'scan')
                ON CONFLICT(topic_id, material_id) DO NOTHING
                """, [topicId, materialId, JSON.string(chunkIds)])
        }
        return byTopic.count
    }

    /// Gives practice problems and old cards a topic: from the AI's topic label, else the problem's own words, else the
    /// one topic their file covers. Never moves anything the course builder or the student linked.
    @discardableResult
    func linkPracticeAndCards(courseId: Int) -> Int {
        let topics = topicWords(courseId: courseId)
        guard !topics.isEmpty else { return 0 }
        var covering: [Int: [Int]] = [:]
        for row in (try? db.query("""
            SELECT c.material_id, c.topic_id FROM topic_coverage c JOIN path_topics t ON t.id = c.topic_id WHERE t.course_id = ? AND t.retired = 0
            """, [courseId])) ?? [] { covering[row.i("material_id"), default: []].append(row.i("topic_id")) }
        // A topic that retired or belongs to another course (the file moved) is as good as none.
        let live = Set(topics.map(\.id))
        func unlinked(_ id: Int?) -> Bool { id.map { !live.contains($0) } ?? true }
        var linked = 0
        for item in practiceItems(courseId: courseId) where unlinked(item.topicId) {
            let fromLabel = item.topicLabel.flatMap { TopicLinker.bestTopic(for: $0, topics: topics, minimum: 0.34) }
            let fromText = fromLabel ?? TopicLinker.bestTopic(for: String(item.promptMd.prefix(400)), topics: topics)
            let fromFile = item.materialId.flatMap { covering[$0] }.flatMap { $0.count == 1 ? $0.first : nil }
            let topic = fromText ?? fromFile
            guard topic != nil || item.topicId != nil else { continue }
            _ = try? db.execute("UPDATE practice_items SET topic_id = ? WHERE id = ? AND topic_id IS ?", [topic, item.id, item.topicId])
            if topic != nil { linked += 1 }
        }
        for card in cards(courseId: courseId, status: nil) where unlinked(card.topicId) {
            let fromText = TopicLinker.bestTopic(for: card.front + " " + card.back, topics: topics)
            let fromFile = card.materialId.flatMap { covering[$0] }.flatMap { $0.count == 1 ? $0.first : nil }
            let topic = fromText ?? fromFile
            guard topic != nil || card.topicId != nil else { continue }
            _ = try? db.execute("UPDATE cards SET topic_id = ? WHERE id = ? AND topic_id IS ?", [topic, card.id, card.topicId])
            if topic != nil { linked += 1 }
        }
        return linked
    }
}
