import Foundation
import StudyCore

/// "Copy for any chatbot": a self-contained prompt for AI apps that can't reach Study Tracker (free ChatGPT, Gemini,
/// Brave Leo, duck.ai…), and an importer for the JSON answer the student pastes back. The answer goes through the
/// same checks and tools as every other engine, so a chatbot can't save anything an MCP client couldn't.
public struct PastePrompts {
    public let store: StudyStore
    public init(store: StudyStore) { self.store = store }

    public static let supported: Set<AITask> = [.process, .extractDeadlines]

    static let lectureExample = """
    {
      "concepts": [{"name": "…", "definition": "one plain sentence", "importance": 1, "source_chunk_ids": [123], "links": [{"to_name": "…", "relation": "part_of"}]}],
      "questions": [{"kind": "recall", "prompt": "…", "answer_key": "…", "concept_name": "…", "source_chunk_ids": [123], "difficulty": 2}],
      "cards": [{"front": "…", "back": "…", "concept_name": "…", "source_chunk_ids": [123]}],
      "cues": [{"text": "a question or key term with no answer", "kind": "question", "source_chunk_ids": [123]}],
      "summary_prompt": "one line the student answers in their own words",
      "hardest_topics": ["topic: short reason"]
    }
    """

    static let deadlineExample = """
    {"items": [{"title": "…", "kind": "report", "due_at": "2026-10-06T23:59:00+02:00", "weight_pct": 30, "source_locator": "p. 4"}]}
    """

    /// One or more prompts to paste in order. Long material is split so each part fits a free chatbot's message limit.
    public func prompts(_ task: AITask, materialId: Int, charLimit: Int = 45_000, now: Date = Date()) throws -> [String] {
        guard Self.supported.contains(task) else { throw AIError.unavailable("\(task.label) needs an AI that can talk with Study Tracker.") }
        guard let material = store.material(materialId) else { throw AIError.badResponse("Material \(materialId) no longer exists.") }
        let chunks = store.chunks(materialId: materialId)
        guard !chunks.isEmpty else { throw AIError.unavailable("\(material.title) has no text yet.") }
        var parts: [[String]] = [[]]
        var size = 0
        for c in chunks {
            let t = Pipelines.render(c, maxChars: charLimit / 2)
            if size + t.count > charLimit, !parts[parts.count - 1].isEmpty { parts.append([]); size = 0 }
            parts[parts.count - 1].append(t); size += t.count
        }
        let course = material.courseId.flatMap { store.course($0) }?.displayName ?? "unknown"
        let existing = material.courseId.map { store.concepts(courseId: $0).map(\.name) } ?? []
        return parts.enumerated().map { i, texts in
            let partLine = parts.count > 1 ? "This is part \(i + 1) of \(parts.count). Answer for this part only; I'll paste every answer back together.\n" : ""
            let body: String
            switch task {
            case .extractDeadlines:
                body = Pipelines.deadlineInstructions(now: now, tz: store.timezone) + "\n\nReply with ONLY a JSON object like this (no other text):\n" + Self.deadlineExample
            default:
                let n = parts.count
                func per(_ total: Int) -> Int { max(1, Int((Double(total) / Double(n)).rounded(.up))) }
                body = """
                Course: \(course). Material: "\(material.title)".
                Concepts that already exist in this course (reuse the exact name when this material covers one): \(existing.isEmpty ? "none" : existing.prefix(60).joined(separator: "; ")).

                \(Pipelines.lectureInstructions(concepts: per(12), questions: per(16), cards: per(10)))
                - cues: up to \(per(16)) Cornell-sheet cues: short questions or key terms with NO answers.
                - summary_prompt and hardest_topics (three, each with a short reason).

                Reply with ONLY a JSON object like this (no other text):
                \(Self.lectureExample)
                """
            }
            return """
            \(Pipelines.rules)
            \(partLine)
            \(body)

            Material:
            \(texts.joined(separator: "\n\n"))
            """
        }
    }

    /// Every top-level JSON object in pasted text (several answers pasted together, or wrapped in prose or code fences).
    public static func objects(in text: String) -> [JSONValue] {
        var out: [JSONValue] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0, inString = false, escaped = false, j = i
            while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j < chars.count, let v = try? JSONValue.parse(String(chars[i...j])) else { i += 1; continue }
            out.append(v)
            i = j + 1
        }
        return out
    }

    /// Imports a pasted answer. Items that don't cite this material, or dates that aren't clear, are reported, not saved.
    public func importAnswer(_ task: AITask, materialId: Int, text: String, host: MCPToolHost) async throws -> PipelineReport {
        let answers = Self.objects(in: text)
        guard !answers.isEmpty else { throw AIError.badResponse("No JSON was found in what you pasted. Paste the chatbot's whole answer.") }
        guard let material = store.material(materialId) else { throw AIError.badResponse("Material \(materialId) no longer exists.") }
        var report = PipelineReport(summary: "")
        switch task {
        case .extractDeadlines:
            guard let courseId = material.courseId else { throw AIError.unavailable("Put \(material.title) in a course first.") }
            await Pipelines.saveDeadlines(Pipelines.deadlineArgs(answers, courseId: courseId, materialId: materialId, report: &report),
                                          material: material, host: host, report: &report)
        default:
            let chunks = store.chunks(materialId: materialId)
            let existing = material.courseId.map { store.concepts(courseId: $0).map(\.name) } ?? []
            let draft = Pipelines.merge(answers, validIds: Set(chunks.map(\.id)), existing: existing, report: &report)
            try await Pipelines.save(draft, material: material, pictureChunks: chunks.filter { $0.imageCount > 0 }.map(\.id), existing: existing,
                                     engineName: "a pasted chatbot answer", host: host, report: &report)
        }
        return report
    }
}
