import Foundation

public extension StudyStore {
    /// With no AI at all a course still gets a path: one topic per lecture or reading, in the order the course taught
    /// them, and a notebook page that lists each one's slide headings as words to look up. The course builder or free AI
    /// replaces it later, and everything the student did carries over. Never replaces a path the course already has.
    @discardableResult
    func buildSkeletonPath(courseId: Int) throws -> PathSaveResult? {
        guard path(courseId: courseId) == nil else { return nil }
        let files = materials(courseId: courseId).filter { !$0.excluded && $0.status == "ready" && ($0.role == .lecture || $0.role == .reading) }
        guard !files.isEmpty else { return nil }
        let ordered = files.sorted { a, b in
            (a.taughtOn?.string ?? "9999", a.importedAt, a.id) < (b.taughtOn?.string ?? "9999", b.importedAt, b.id)
        }
        var seen = Set<String>()
        // A path holds at most 80 topics: past that, the earliest-taught files make the outline.
        let topics: [PathInput.Topic] = Array(ordered.compactMap { m -> PathInput.Topic? in
            let title = Self.skeletonName(m)
            guard seen.insert(Self.topicKey(title)).inserted else { return nil }
            return PathInput.Topic(title: title, estMinutes: 25, sources: [PathInput.Source(materialId: m.id)])
        }.prefix(80))
        let units: [PathInput.Unit]
        if topics.count <= 8 {
            units = [PathInput.Unit(title: "Lectures", topics: topics)]
        } else {
            let size = Int((Double(topics.count) / ceil(Double(topics.count) / 6)).rounded(.up))
            units = stride(from: 0, to: topics.count, by: size).enumerated().map { i, start in
                PathInput.Unit(title: "Part \(i + 1)", topics: Array(topics[start..<min(topics.count, start + size)]))
            }
        }
        let result = try savePath(courseId: courseId, PathInput(units: Array(units.prefix(16))), tier: "skeleton", builtWith: "Study Tracker",
                                  createdBy: "app")
        // Each topic's notebook page: the headings its slides use, as words to look up.
        var pages: [NotebookInput] = []
        for m in ordered {
            guard let topicId = result.topicIds[Self.topicKey(Self.skeletonName(m))] else { continue }
            var terms: [NotebookTerm] = []
            var heads = Set<String>()
            for c in chunks(materialId: m.id) {
                guard let h = c.heading?.trimmingCharacters(in: .whitespacesAndNewlines), h.count >= 3, h.count <= 80,
                      !Self.boilerplateHeading(h), heads.insert(h.lowercased()).inserted else { continue }
                terms.append(NotebookTerm(term: h, definition: "", sourceChunkIds: [c.id]))
                if terms.count == 8 { break }
            }
            if !terms.isEmpty { pages.append(NotebookInput(topicId: topicId, terms: terms)) }
        }
        for start in stride(from: 0, to: pages.count, by: 12) {
            _ = try saveNotebook(courseId: courseId, Array(pages[start..<min(pages.count, start + 12)]), tier: "skeleton", generatedBy: "Study Tracker")
        }
        return result
    }

    /// A file's topic name: its title, or its file name when the title is a slide like "Agenda".
    static func skeletonName(_ m: Material) -> String {
        let useFile = boilerplateHeading(m.title) || m.title.count < 4
        return skeletonTitle(useFile ? FileSorter.stem(m.originalFilename ?? m.title) : m.title)
    }

    /// "Week 3 – Overbooking and no-shows (1)" → "Overbooking and no-shows".
    static func skeletonTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: #"[_]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)^\s*(week|wk|w|lecture|lec|session|class|lesson|topic|unit|chapter|ch|l|vl|tema|sesion|sesión|semana|vorlesung|cours)\s*\d+\s*[-–—:.)]*\s*"#,
                                   with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\s*[-–_ ]\s*(final|v\d+|copy|slides?)\s*$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? title : String(t.prefix(1).uppercased() + t.dropFirst())
    }

    static func boilerplateHeading(_ h: String) -> Bool {
        let l = h.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let skip = ["agenda", "questions", "any questions", "thank you", "thanks", "summary", "references", "bibliography", "outline", "contents",
                    "learning objectives", "objectives", "today", "overview", "recap", "q&a", "discussion", "introduction", "welcome", "end",
                    "table of contents", "preface", "foreword", "about the author", "about the authors", "acknowledgments", "acknowledgements",
                    "copyright", "index", "glossary", "dedication", "brief contents", "title page"]
        return skip.contains(l) || l.range(of: #"^(slide|page)?\s*\d+$"#, options: .regularExpression) != nil
            || l.range(of: #"^[ivxlc]+$"#, options: .regularExpression) != nil
            || l.range(of: #"^(chapter|topic|unit|week|lecture|session)\s*\d+(\s*outline)?$"#, options: .regularExpression) != nil
    }
}
