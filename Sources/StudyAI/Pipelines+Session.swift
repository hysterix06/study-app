import Foundation
import StudyCore

/// Advice during a session, in one request each. It never rates anything: the student's own rating decides.
public struct AnswerCheck: Sendable {
    /// correct, partly, incorrect or unsure.
    public var verdict: String
    public var feedbackMd: String
}

public extension Pipelines {
    static func checkSchema() -> ResponseSchema {
        ResponseSchema(name: "answer_check", schema: [
            "type": "object",
            "properties": ["verdict": ["type": "string", "enum": ["correct", "partly", "incorrect", "unsure"]], "feedback": ["type": "string"]],
            "required": ["verdict", "feedback"],
        ])
    }

    /// Looks at the student's answer to a problem, against the course's solution when there is one.
    func checkAnswer(problem: String, solution: String?, answer: String) async throws -> AnswerCheck {
        var report = PipelineReport(summary: "")
        let prompt = """
        A university student answered a practice problem. Say whether the answer is right, and in 2-4 sentences what is
        right, what is missing or wrong, and the one thing to fix. Don't give a full model answer. Use Markdown, maths in $…$.
        verdict: correct, partly, incorrect, or unsure if you can't tell.

        Problem:
        \(problem.prefix(3_000))
        \(solution.map { "\nThe course's solution:\n\($0.prefix(3_000))\n" } ?? "")
        The student's answer:
        \(answer.prefix(3_000))
        """
        let json = try await structured([.system(Self.courseRules), .user(prompt)], schema: Self.checkSchema(), maxOutput: 600, report: &report)
        return AnswerCheck(verdict: json["verdict"]?.string ?? "unsure", feedbackMd: TextRepair.markdown(json["feedback"]?.string ?? ""))
    }

    static func explainSchema() -> ResponseSchema {
        ResponseSchema(name: "explain_feedback", schema: [
            "type": "object",
            "properties": ["feedback": ["type": "string"], "missing": ["type": "array", "items": ["type": "string"]]],
            "required": ["feedback", "missing"],
        ])
    }

    /// Reads the student's explanation of a topic: what's good, and the key ideas it leaves out.
    func explainFeedback(topic: String, keyIdeas: String, explanation: String) async throws -> (feedbackMd: String, missing: [String]) {
        var report = PipelineReport(summary: "")
        let prompt = """
        A university student explained "\(topic)" in their own words. In 2-3 sentences, say what they got right and what is
        unclear or wrong. missing: the key ideas they left out (short phrases, [] if none). Be encouraging and specific.

        The key ideas of the topic:
        \(keyIdeas.prefix(3_000))

        The student's explanation:
        \(explanation.prefix(2_000))
        """
        let json = try await structured([.system(Self.courseRules), .user(prompt)], schema: Self.explainSchema(), maxOutput: 500, report: &report)
        return (TextRepair.markdown(json["feedback"]?.string ?? ""), (json["missing"]?.array ?? []).compactMap(\.string).prefix(5).map { $0 })
    }
}
