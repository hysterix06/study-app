import Foundation
import StudyCore

/// Reading new course files with free AI, quietly: placing the files the sorting rules weren't sure about, and labelling
/// the problems split out of problem sets, class examples and past exams. Both fit Apple's on-device model.
public extension Pipelines {
    // MARK: Sort files

    static func sortSchema() -> ResponseSchema {
        ResponseSchema(name: "file_sort", schema: [
            "type": "object",
            "properties": ["files": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "n": ["type": "integer"],
                    "role": ["type": "string", "enum": .array(MaterialRole.allCases.map { .string($0.rawValue) })],
                    "confidence": ["type": "number"],
                    "reason": ["type": "string"],
                ],
                "required": ["n", "role", "confidence", "reason"],
            ]]],
            "required": ["files"],
        ])
    }

    static let sortInstructions = """
    Each file below comes from one university course. Say what each file is:
    - lecture: slides or notes from a class
    - reading: an article, a book chapter or a case study to read
    - practice: problem sets, exercises, tutorials, worksheets, quizzes, or their solutions
    - example: worked examples or activities shown in class
    - syllabus: course outline, schedule, learning outcomes, how the course is graded
    - rubric: marking criteria
    - brief: instructions for an assignment or project
    - past_exam: an old exam, a mock exam, or its solutions
    - other: doesn't belong in the course (admin, sign-up sheets, templates, unrelated or unreadable)
    confidence: 0 to 1. reason: one short sentence a student understands, e.g. "Numbered exercises with solutions."
    """

    /// Places up to eight files the rules weren't sure about. Files the student sorted are never touched.
    func sortFiles(materialIds: [Int], progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PipelineReport {
        let files = materialIds.compactMap { store.material($0) }.filter { $0.roleSource != "user" }.prefix(8)
        var report = PipelineReport(summary: "")
        guard !files.isEmpty else { report.summary = "Nothing to sort."; return report }
        progress(files.count == 1 ? "Sorting \(files[files.startIndex].title)" : "Sorting \(files.count) files")
        let perFile = max(200, min(400, sectionBudget * 3 / files.count))
        let listing = files.enumerated().map { i, m -> String in
            let first = store.chunks(materialId: m.id, toOrdinal: 2).map { [$0.heading, $0.textMd].compactMap { $0 }.joined(separator: " ") }
                .joined(separator: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            var head = "[\(i + 1)] \(m.originalFilename ?? m.title)"
            if let s = m.sectionName { head += " · Moodle section: \(s)" }
            if let mod = m.moduleName { head += " · Moodle activity: \(mod)" }
            return head + "\n" + String(first.prefix(perFile))
        }.joined(separator: "\n\n")
        let json = try await structured([.system(Self.rules), .user(Self.sortInstructions + "\n\n" + listing)], schema: Self.sortSchema(),
                                        maxOutput: 300 + 80 * files.count, report: &report)
        var sorted = 0
        for f in json["files"]?.array ?? [] {
            guard let n = f["n"]?.int, (1...files.count).contains(n), let role = f["role"]?.string, MaterialRole(rawValue: role) != nil else { continue }
            let m = files[files.startIndex + n - 1]
            let r = await host.callJSON("set_material_use", ["material_id": m.id, "role": role, "confidence": min(1, max(0, f["confidence"]?.number ?? 0.5)),
                                                             "reason": String((f["reason"]?.string ?? "Sorted by AI.").prefix(200))])
            if r.ok { sorted += 1 } else { report.warnings.append("\(m.title): \(r.text.prefix(120))") }
        }
        report.counts["files"] = sorted
        report.summary = sorted == 1 ? "Sorted 1 file." : "Sorted \(sorted) files."
        return report
    }

    // MARK: Label practice problems

    static func labelSchema() -> ResponseSchema {
        ResponseSchema(name: "practice_labels", schema: [
            "type": "object",
            "properties": ["items": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "id": ["type": "integer"],
                    "kind": ["type": "string", "enum": .array(PracticeItem.kinds.filter { $0 != "other" }.map { .string($0) })],
                    "difficulty": ["type": "integer"],
                    "topic": ["type": "string"],
                    "marks": ["type": "number"],
                ],
                "required": ["id", "kind", "difficulty", "topic", "marks"],
            ]]],
            "required": ["items"],
        ])
    }

    /// Labels the problems split out of one file (kind, difficulty, a short topic name, marks). The text never changes.
    func labelPractice(materialId: Int, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PipelineReport {
        guard let material = store.material(materialId) else { throw AIError.badResponse("Material \(materialId) no longer exists.") }
        let items = store.practiceItems(materialId: materialId).filter(\.isUnlabelled)
        var report = PipelineReport(summary: "")
        guard !items.isEmpty else { report.summary = "Nothing to label."; return report }
        let exam = material.role == .pastExam
        let perItem = 300
        let batch = max(4, min(20, sectionBudget * 3 / perItem))
        var labelled = 0
        for start in stride(from: 0, to: items.count, by: batch) {
            let part = Array(items[start..<min(items.count, start + batch)])
            progress(items.count <= batch ? "Reading \(material.title)" : "Reading \(material.title), \(start + part.count) of \(items.count)")
            let listing = part.map { i in
                "[\(i.id)] \(i.number.map { "#\($0) " } ?? "")" + String(i.promptMd.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(perItem))
            }.joined(separator: "\n")
            let prompt = """
            These are \(exam ? "questions from a past exam" : "practice problems") from "\(material.title)". For each one give:
            kind: calculate (numbers to work out), short (a short answer), explain, apply (use an idea on a case), compare, mcq (multiple \
            choice), essay, proof or case (a longer case study).
            difficulty: 1 easy, 2 medium, 3 hard. topic: 2-6 words naming what it practises, in the language of the problem.
            marks: the marks it states, or -1.

            \(listing)
            """
            let json = try await structured([.system(Self.rules), .user(prompt)], schema: Self.labelSchema(), maxOutput: 200 + 60 * part.count, report: &report)
            let valid = Set(part.map(\.id))
            let labels: [[String: Any]] = (json["items"]?.array ?? []).compactMap { l in
                guard let id = l["id"]?.int, valid.contains(id) else { return nil }
                var d: [String: Any] = ["id": id]
                if let k = l["kind"]?.string, PracticeItem.kinds.contains(k) { d["kind"] = k }
                if let x = l["difficulty"]?.int { d["difficulty"] = min(3, max(1, x)) }
                if let t = l["topic"]?.string?.trimmingCharacters(in: .whitespaces), !t.isEmpty { d["topic"] = String(t.prefix(80)) }
                if let m = l["marks"]?.number, m > 0, m <= 200 { d["marks"] = m }
                return d
            }
            guard !labels.isEmpty else { continue }
            let r = await host.callJSON("label_practice_items", ["material_id": materialId, "items": labels])
            if r.ok { labelled += labels.count } else { report.warnings.append("Labels weren't saved: \(r.text.prefix(160))") }
        }
        report.counts["problems"] = labelled
        report.summary = "Labelled \(labelled) problem\(labelled == 1 ? "" : "s") in \(material.title)."
        return report
    }
}
