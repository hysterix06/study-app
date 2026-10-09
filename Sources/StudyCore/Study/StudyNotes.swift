import Foundation

/// A lecture's slides, reorganized into notes worth reading: only what a student needs, in a sensible order, with
/// diagrams drawn by the app. Made once when a lecture is processed and stored as a `summary` note (the structure in
/// `data_json`, readable Markdown in `content_md`). Everything after that (chats, quizzes, course notes) reads these
/// few hundred tokens instead of the whole deck.
public struct StudyNotes: Codable, Equatable, Sendable {
    public enum PointKind: String, Codable, CaseIterable, Sendable {
        case point, definition, formula, example, caution
        public var label: String {
            switch self {
            case .point: return "Point"
            case .definition: return "Definition"
            case .formula: return "Formula"
            case .example: return "Example"
            case .caution: return "Watch out"
            }
        }
    }

    public struct Point: Codable, Equatable, Sendable {
        public var text: String
        public var kind: PointKind
        /// Where it comes from: "slide 4", "p. 2".
        public var sources: [String]
        public init(text: String, kind: PointKind = .point, sources: [String] = []) { self.text = text; self.kind = kind; self.sources = sources }
    }

    public struct Section: Codable, Equatable, Sendable {
        public var title: String
        public var points: [Point]
        public var diagram: Diagram?
        public init(title: String, points: [Point], diagram: Diagram? = nil) { self.title = title; self.points = points; self.diagram = diagram }
    }

    public struct Term: Codable, Equatable, Sendable {
        public var term: String
        public var definition: String
        public init(term: String, definition: String) { self.term = term; self.definition = definition }
    }

    /// Marks the note's data as study notes (summaries from chats share the note kind).
    public var type = "study_notes"
    public var materialTitle: String
    public var courseCode: String
    public var date: String
    public var overview: String
    public var sections: [Section]
    public var terms: [Term]
    public var takeaways: [String]

    public init(materialTitle: String, courseCode: String, date: String, overview: String, sections: [Section], terms: [Term] = [], takeaways: [String] = []) {
        self.materialTitle = materialTitle; self.courseCode = courseCode; self.date = date; self.overview = overview
        self.sections = sections; self.terms = terms; self.takeaways = takeaways
    }

    public static let noteKind = "summary"
    public static func noteTitle(_ materialTitle: String) -> String { String("Study notes · \(materialTitle)".prefix(160)) }

    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(_ s: String?) -> StudyNotes? {
        guard let s, s.contains("\"study_notes\""), let n = try? JSONDecoder().decode(StudyNotes.self, from: Data(s.utf8)), n.type == "study_notes" else { return nil }
        return n
    }

    /// JSON Schema for one section, shared by the MCP tool and the pipelines.
    public static func sectionSchema(includeDiagram: Bool) -> [String: Any] {
        var props: [String: Any] = [
            "title": ["type": "string", "description": "Short heading"],
            "points": ["type": "array", "description": "1-10 points in teaching order", "items": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "One idea, at most two sentences. Formulas: the formula, then what each symbol means."],
                    "kind": ["type": "string", "enum": PointKind.allCases.map(\.rawValue)],
                    "source_chunk_ids": ["type": "array", "items": ["type": "integer"]],
                ],
                "required": ["text", "kind", "source_chunk_ids"],
            ] as [String: Any]],
        ]
        if includeDiagram { props["diagram"] = Diagram.jsonSchema }
        return ["type": "object", "properties": props, "required": ["title", "points"]]
    }

    public var formulas: [Point] { sections.flatMap { $0.points.filter { $0.kind == .formula } } }
    public var diagramCount: Int { sections.filter { $0.diagram != nil }.count }

    // MARK: Text forms

    public enum DiagramStyle { case describe, svg }

    /// Readable Markdown. `.svg` embeds the diagrams (Obsidian and most Markdown viewers draw inline SVG);
    /// `.describe` writes one line per diagram.
    public func markdown(diagrams: DiagramStyle = .describe, headingLevel: Int = 1) -> String {
        let h = String(repeating: "#", count: max(1, headingLevel))
        var md = "\(h) \(materialTitle)\n\n"
        if !courseCode.isEmpty || !date.isEmpty { md += [courseCode, date].filter { !$0.isEmpty }.joined(separator: " · ") + "\n\n" }
        if !overview.isEmpty { md += "\(overview)\n\n" }
        for s in sections {
            md += "\(h)# \(s.title)\n\n"
            for p in s.points { md += "- " + Self.line(p) + "\n" }
            if let d = s.diagram {
                md += "\n"
                switch diagrams {
                case .svg: md += DiagramSVG.render(d) + "\n"
                case .describe: md += "_Diagram: \(d.summary)_\n"
                }
            }
            md += "\n"
        }
        if !takeaways.isEmpty { md += "\(h)# Takeaways\n\n" + takeaways.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !terms.isEmpty { md += "\(h)# Key terms\n\n" + terms.map { "- **\($0.term)**: \($0.definition)" }.joined(separator: "\n") + "\n" }
        return md
    }

    static func line(_ p: Point) -> String {
        let src = p.sources.isEmpty ? "" : " _(\(p.sources.prefix(3).joined(separator: ", ")))_"
        switch p.kind {
        case .point: return p.text + src
        case .formula: return "**Formula:** `\(p.text)`" + src
        default: return "**\(p.kind.label):** \(p.text)" + src
        }
    }

    /// The shortest faithful form, for AI context: no Markdown decoration, diagrams as one line.
    public var compact: String {
        var lines = ["\(materialTitle)" + (overview.isEmpty ? "" : ": \(overview)")]
        for s in sections {
            lines.append("## \(s.title)")
            for p in s.points {
                let src = p.sources.isEmpty ? "" : " (\(p.sources.prefix(2).joined(separator: ", ")))"
                lines.append("- " + (p.kind == .point ? "" : "\(p.kind.rawValue): ") + p.text + src)
            }
            if let d = s.diagram { lines.append("- diagram: \(d.summary)") }
        }
        if !takeaways.isEmpty { lines.append("Takeaways: " + takeaways.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Course notes

/// A whole course's notes compiled on this Mac from each lecture's study notes: no AI request at all.
public enum CourseNotesDoc {
    public static func markdown(courseName: String, lectures: [(material: Material, notes: StudyNotes)], concepts: [Concept],
                                diagrams: StudyNotes.DiagramStyle = .describe) -> String {
        var md = "# \(courseName) · Course notes\n\n"
        if !lectures.isEmpty {
            md += "## Contents\n\n" + lectures.enumerated().map { "\($0.offset + 1). \($0.element.material.title)" }.joined(separator: "\n") + "\n\n"
        }
        for l in lectures { md += l.notes.markdown(diagrams: diagrams, headingLevel: 2) + "\n" }
        let formulas = lectures.flatMap { l in l.notes.formulas.map { (l.material.title, $0) } }
        if !formulas.isEmpty {
            md += "## Formula sheet\n\n" + formulas.map { "- `\($0.1.text)` _(\($0.0))_" }.joined(separator: "\n") + "\n\n"
        }
        let glossary = concepts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !glossary.isEmpty { md += "## Glossary\n\n" + glossary.map { "- **\($0.name)**: \($0.definition)" }.joined(separator: "\n") + "\n" }
        return md
    }
}

// MARK: - Store

public extension StudyStore {
    struct NotePointInput {
        public var text: String; public var kind: String; public var sourceChunkIds: [Int]
        public init(text: String, kind: String, sourceChunkIds: [Int]) { self.text = text; self.kind = kind; self.sourceChunkIds = sourceChunkIds }
    }

    struct NoteSectionInput {
        public var title: String; public var points: [NotePointInput]
        /// Loose JSON from the AI; checked by `Diagram.parse`.
        public var diagram: Any?
        public init(title: String, points: [NotePointInput], diagram: Any? = nil) { self.title = title; self.points = points; self.diagram = diagram }
    }

    /// Saves (or replaces) the AI's study notes for a lecture. Every point cites chunks of this material; key terms
    /// come from the lecture's saved concepts, so they cost nothing extra to generate.
    func saveStudyNotes(materialId: Int, overview: String, sections: [NoteSectionInput], takeaways: [String]) throws -> WriteResult {
        let (m, courseId) = try requireMaterialWithCourse(materialId)
        guard (1...16).contains(sections.count) else { throw ToolError.invalid("Study notes need 1-16 sections (got \(sections.count)).") }
        guard overview.count <= 600 else { throw ToolError.invalid("overview must be at most 600 characters.") }
        guard takeaways.count <= 8, takeaways.allSatisfy({ $0.count <= 300 }) else { throw ToolError.invalid("At most 8 takeaways of up to 300 characters.") }
        var out: [StudyNotes.Section] = []
        var warnings: [String] = []
        for s in sections {
            let title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 100 else { throw ToolError.invalid("Each section title must be 1-100 characters.") }
            guard s.points.count <= 12 else { throw ToolError.invalid("Section \"\(title.prefix(40))\" has \(s.points.count) points; the limit is 12.", hint: "Split it into two sections.") }
            var points: [StudyNotes.Point] = []
            for p in s.points {
                let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 500 else { throw ToolError.invalid("Each point must be 1-500 characters.", hint: "One idea per point.") }
                guard let kind = StudyNotes.PointKind(rawValue: p.kind) else {
                    throw ToolError.invalid("Point kind must be one of \(StudyNotes.PointKind.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                points.append(.init(text: text, kind: kind, sources: try validateChunks(p.sourceChunkIds, materialId: materialId)))
            }
            let (diagram, w) = Diagram.parse(s.diagram)
            warnings += w
            guard !points.isEmpty || diagram != nil else { continue }
            out.append(.init(title: title, points: points, diagram: diagram))
        }
        guard !out.isEmpty else { throw ToolError.invalid("Every section was empty.") }
        let terms = concepts(materialId: materialId).sorted { $0.importance < $1.importance }.prefix(20).map { StudyNotes.Term(term: $0.name, definition: $0.definition) }
        let notes = StudyNotes(materialTitle: m.title, courseCode: course(courseId)?.displayName ?? "", date: LocalDate.today(tz: timezone).string,
                               overview: overview.trimmingCharacters(in: .whitespacesAndNewlines), sections: out, terms: Array(terms),
                               takeaways: takeaways.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        var r = try saveClaudeNote(courseId: courseId, materialId: materialId, kind: StudyNotes.noteKind, title: StudyNotes.noteTitle(m.title),
                                   content: notes.markdown(), dataJson: notes.json)
        r.warnings += warnings
        return r
    }

    /// The newest study notes for a material.
    func studyNotes(materialId: Int) -> (note: Note, notes: StudyNotes)? {
        for n in notes(materialId: materialId, kind: StudyNotes.noteKind) {
            if let s = StudyNotes.decode(n.dataJson) { return (n, s) }
        }
        return nil
    }

    /// Every lecture in a course that has study notes, in lecture order ("Week 2" before "Week 10").
    func courseStudyNotes(courseId: Int) -> [(material: Material, notes: StudyNotes)] {
        materials(courseId: courseId).compactMap { m in studyNotes(materialId: m.id).map { (m, $0.notes) } }
            .sorted { $0.material.title.compare($1.material.title, options: [.numeric, .caseInsensitive]) == .orderedAscending }
    }

    /// Approves a lecture's proposed flashcards in one go, so the starter deck is ready for review.
    @discardableResult
    func approveProposedCards(materialId: Int) throws -> Int {
        var n = 0
        try db.transaction {
            n = try db.scalarInt("SELECT count(*) FROM cards WHERE material_id = ? AND status = 'proposed'", [materialId])
            try db.execute("UPDATE cards SET status = 'active', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE material_id = ? AND status = 'proposed'", [materialId])
            audit("approve_cards", entity: "material", id: materialId, detail: ["count": n])
        }
        return n
    }
}

// MARK: - Condensing slides before an AI reads them

/// Strips what costs tokens without teaching anything, on this Mac, before a lecture goes to an AI: footers and
/// headers repeated on every slide, slide numbers, "Thank you" and "Questions?" slides, repeated agenda slides, and
/// overlong speaker notes. Chunk ids stay the same, so citations still point at the original slides.
public enum MaterialCondenser {
    public struct Result {
        public var chunks: [Chunk]
        public var dropped: Int
        public var tokensBefore: Int
        public var tokensAfter: Int
    }

    static let fillerPattern = #"^(thank(s| you)( for (listening|your attention))?|questions\??|any questions\??|q ?& ?a|discussion|break|the end|end|fin|merci)[.!?]*$"#
    static let noisePattern = #"^((slide|page|p\.)\s*\d+(\s*(of|/)\s*\d+)?|\d{1,3}(\s*(of|/)\s*\d{1,3})?|©.*|copyright.*|all rights reserved.*)$"#

    public static func condense(_ chunks: [Chunk], maxNotes: Int = 800, maxExtra: Int = 1_500) -> Result {
        let before = chunks.reduce(0) { $0 + $1.tokenEstimate }
        // Lines repeated on many slides are headers and footers.
        var seenIn: [String: Int] = [:]
        for c in chunks {
            for key in Set(lines(c.textMd).map(normalize)) where !key.isEmpty { seenIn[key, default: 0] += 1 }
        }
        let threshold = max(3, Int((Double(chunks.count) * 0.4).rounded(.up)))
        let boilerplate: Set<String> = chunks.count >= 4 ? Set(seenIn.filter { $0.value >= threshold && $0.key.count <= 120 }.keys) : []

        var out: [Chunk] = []
        var seenBodies = Set<String>()
        for c in chunks {
            var kept: [String] = []
            for line in lines(c.textMd) {
                let key = normalize(line)
                if key.isEmpty || boilerplate.contains(key) || key.range(of: noisePattern, options: .regularExpression) != nil { continue }
                if kept.last.map(normalize) == key { continue }
                kept.append(line)
            }
            // A heading repeated as the first line.
            if let h = c.heading, let first = kept.first, normalize(first) == normalize(h) { kept.removeFirst() }
            let text = kept.joined(separator: "\n")
            let notes = c.notesMd.map { clip($0.trimmingCharacters(in: .whitespacesAndNewlines), maxNotes) }.flatMap { $0.isEmpty ? nil : $0 }
            let extra = c.extraMd.map { clip($0.trimmingCharacters(in: .whitespacesAndNewlines), maxExtra) }.flatMap { $0.isEmpty ? nil : $0 }
            let body = normalize([c.heading ?? "", text].joined(separator: " "))
            let words = body.split(separator: " ").count
            if text.isEmpty && notes == nil && extra == nil { continue }
            if notes == nil && extra == nil && words <= 6 && body.range(of: fillerPattern, options: .regularExpression) != nil { continue }
            if notes == nil && !body.isEmpty && !seenBodies.insert(body).inserted { continue }
            // Scale the parser's estimate by how much text is left, so sectioning stays consistent with it.
            let oldChars = max(1, c.textMd.count + (c.notesMd?.count ?? 0) + (c.extraMd?.count ?? 0))
            let newChars = text.count + (notes?.count ?? 0) + (extra?.count ?? 0)
            let estimate = newChars >= oldChars ? c.tokenEstimate : max(1, Int((Double(c.tokenEstimate) * Double(newChars) / Double(oldChars)).rounded(.up)))
            out.append(Chunk(id: c.id, materialId: c.materialId, ordinal: c.ordinal, locator: c.locator, heading: c.heading, textMd: text,
                             notesMd: notes, extraMd: extra, imageCount: c.imageCount, images: c.images, ocr: c.ocr, tokenEstimate: estimate))
        }
        // Never hand an AI nothing: if everything looked like noise, keep the original.
        if out.isEmpty { return Result(chunks: chunks, dropped: 0, tokensBefore: before, tokensAfter: before) }
        return Result(chunks: out, dropped: chunks.count - out.count, tokensBefore: before, tokensAfter: out.reduce(0) { $0 + $1.tokenEstimate })
    }

    /// Non-empty lines, indentation kept (it carries the bullet hierarchy).
    static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { line in
            var l = String(line)
            while let last = l.last, last.isWhitespace { l.removeLast() }
            return l
        }.filter { l in l.contains { $0.isLetter || $0.isNumber } }
    }

    /// Lower-cased, bullets and punctuation runs trimmed, spaces collapsed.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"^[\s\-*•·▪◦–—>#\d.)]*\s"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
}
