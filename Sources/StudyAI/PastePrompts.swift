import Foundation
import StudyCore

/// "Copy for any chatbot": a self-contained prompt for AI apps that can't reach Study Tracker (free ChatGPT, Gemini,
/// Brave Leo, duck.ai…), and an importer for the JSON answer the student pastes back. The answer goes through the
/// same checks and tools as every other engine, so a chatbot can't save anything an MCP client couldn't.
public struct PastePrompts {
    public let store: StudyStore
    public init(store: StudyStore) { self.store = store }

    public static let supported: Set<AITask> = [.extractDeadlines, .buildPath, .writeNotebook, .writeLessons]

    static let deadlineExample = """
    {"items": [{"title": "…", "kind": "report", "due_at": "2026-10-06T23:59:00+02:00", "weight_pct": 30, "source_locator": "p. 4"}],
     "outcomes": ["…"], "schedule": [{"week": 1, "date": "", "topic": "…"}], "assessment": [{"title": "…", "weight_pct": 40, "covers": ["…"]}]}
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
        return parts.enumerated().map { i, texts in
            let partLine = parts.count > 1 ? "This is part \(i + 1) of \(parts.count). Answer for this part only; I'll paste every answer back together.\n" : ""
            let body = Pipelines.deadlineInstructions(now: now, tz: store.timezone) + "\n\nReply with ONLY a JSON object like this (no other text):\n" + Self.deadlineExample
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
        guard let courseId = material.courseId else { throw AIError.unavailable("Put \(material.title) in a course first.") }
        await Pipelines.saveDeadlines(Pipelines.deadlineArgs(answers, courseId: courseId, materialId: materialId, report: &report),
                                      material: material, host: host, report: &report)
        await Pipelines.saveSyllabusScan(answers, materialId: materialId, host: host, report: &report)
        return report
    }
}
