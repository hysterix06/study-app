import SwiftUI
import StudyCore
import StudyAI

/// A session in progress: where the student is, what each step shows, and saving after every step so closing the
/// window never loses anything (Home offers Continue).
@MainActor
@Observable
final class SessionController: Identifiable {
    unowned let model: AppModel
    private(set) var session: StudySession
    private(set) var progress: SessionProgress
    private(set) var step: SessionStep
    let kind: SessionKind
    let startedAt = Date()
    /// Mastery when the session started, for the summary at the end.
    let masteryBefore: [Int: Mastery]

    // Step state.
    var cards: CardQueue?
    var answer = ""
    var solutionShown = false
    var hintsShown = 0
    var check: AnswerCheck?
    var checking = false
    var aiError: String?
    var explanation = ""
    var feedback: (md: String, missing: [String])?
    var pageShown = false
    var pageNumber = ""
    var drafts: [CardDraft] = []
    var summary: SessionSummary?
    var problemStarted = Date()
    /// Bumped whenever the step, problem or topic on screen changes, so a late AI reply for an earlier one is dropped.
    @ObservationIgnored private var asking = 0

    nonisolated let id: Int

    init(session: StudySession, model: AppModel) {
        self.model = model
        self.id = session.id
        self.session = session
        let progress = session.progress ?? SessionProgress(steps: [.done])
        self.progress = progress
        self.kind = SessionKind(rawValue: session.kind) ?? .review
        self.step = session.currentStep
        let ids = Set(progress.topicIds + [session.topicId].compactMap { $0 })
        masteryBefore = Dictionary(uniqueKeysWithValues: ids.compactMap { id in model.store.topic(id).map { (id, $0.mastery) } })
        enter(step)
    }

    var store: StudyStore { model.store }
    var mode: SessionMode { session.sessionMode }
    var course: Course? { session.courseId.flatMap { store.course($0) } }

    /// The topic on screen: the session's topic, or the page or exam topic it's on.
    var topic: PathTopic? {
        if let t = session.topicId { return store.topic(t) }
        guard progress.index < progress.topicIds.count else { return nil }
        return store.topic(progress.topicIds[progress.index])
    }

    var numbers: [Int: String] { session.courseId.map { store.topicNumbers(courseId: $0) } ?? [:] }

    var title: String {
        switch kind {
        case .notebook: return "Notebook"
        case .review: return "Review"
        case .examPrep: return session.assignmentId.flatMap { store.assignment($0) }.map { "Exam prep · \($0.title)" } ?? "Exam prep"
        case .topic: return topic.map { "\(numbers[$0.id].map { "\($0) " } ?? "")\($0.title)" } ?? "Topic"
        }
    }

    // MARK: Moving through

    /// Sets a step up: due cards for the warm-up, the lesson's cards to keep at the end.
    private func enter(_ s: SessionStep) {
        moved()
        switch s {
        case .warmup:
            cards = CardQueue(store.reviewQueue(courseId: session.courseId, limit: mode.warmupCards))
            if cards?.cards.isEmpty ?? true { return next() }
        case .cards:
            cards = CardQueue(store.reviewQueue(courseId: session.courseId, limit: mode.reviewCards))
        case .practice:
            startProblem()
        case .lockin:
            if kind == .topic, let t = session.topicId {
                drafts = (store.lesson(topicId: t)?.cards ?? []).map { CardDraft(front: $0.front, back: $0.back) }
            }
        default: break
        }
    }

    func save() {
        try? store.saveSession(session.id, step: step, progress: progress)
    }

    /// The next step, or the end of the session.
    func next() {
        let i = progress.steps.firstIndex(of: step) ?? progress.steps.count
        progress.index = 0
        if i + 1 < progress.steps.count {
            step = progress.steps[i + 1]
            save()
            enter(step)
            if step == .lockin && kind != .topic { lockIn() }
        } else {
            finish()
        }
        model.refresh()
    }

    /// The next page, problem or exam topic within a step; the next step after the last.
    func nextItem(count: Int) {
        if progress.index + 1 < count {
            progress.index += 1
            save()
            moved()
            if step == .practice { startProblem() }
            pageShown = false
            pageNumber = topic?.notebookPage ?? ""
        } else {
            next()
        }
    }

    /// Leaves the session where it is; Continue picks it up.
    func close() {
        save()
        model.session = nil
        model.refresh()
    }

    func finish() {
        if step != .done {
            try? store.finishSession(session.id, summary: summaryLine)
            step = .done
        }
        let after = Dictionary(uniqueKeysWithValues: masteryBefore.keys.compactMap { id in store.topic(id).map { (id, $0) } })
        summary = SessionSummary(
            topics: masteryBefore.keys.sorted().compactMap { id in after[id].map { (title: $0.title, before: masteryBefore[id] ?? .new, after: $0.mastery) } },
            cardsReviewed: cards?.ratings.count ?? 0, recalled: cards?.recalled ?? 0, kept: progress.cardsKept.count,
            next: store.nextSessionPlan().primary)
        model.refresh()
    }

    var summaryLine: String {
        switch kind {
        case .notebook: return "Wrote \(progress.topicIds.filter { store.topic($0)?.inNotebook ?? false }.count) notebook pages."
        case .review: return "Reviewed \(cards?.ratings.count ?? 0) cards; recalled \(cards?.recalled ?? 0)."
        case .topic: return "Studied \(topic?.title ?? "a topic")."
        case .examPrep: return "Exam prep: reviewed \(progress.topicIds.count) topics."
        }
    }

    private func moved() {
        asking += 1
        checking = false
        aiError = nil
    }

    // MARK: Notebook pages

    func pageWritten() {
        guard let t = topic else { return }
        try? store.setNotebookWritten(t.id, written: true, page: pageNumber.trimmingCharacters(in: .whitespaces))
        nextItem(count: progress.topicIds.count)
    }

    // MARK: Practice

    var problems: [PracticeItem] { progress.problemIds.compactMap { store.practiceItem($0) } }
    var problem: PracticeItem? { progress.index < progress.problemIds.count ? store.practiceItem(progress.problemIds[progress.index]) : nil }

    private func startProblem() {
        answer = ""; solutionShown = false; hintsShown = 0; check = nil; aiError = nil; problemStarted = Date()
    }

    func checkAnswer() {
        guard let p = problem, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        checking = true; aiError = nil
        asking += 1
        let ticket = asking
        let answer = self.answer
        Task {
            do {
                let r = try await model.ai.inline(.checkAnswer, { try await $0.checkAnswer(problem: p.promptMd, solution: p.solutionMd, answer: answer) })
                guard ticket == asking else { return }
                checking = false
                guard let r else { aiError = "Checking needs Everyday AI. Turn it on in Settings › AI."; return }
                check = r
            } catch {
                guard ticket == asking else { return }
                checking = false
                aiError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// The student's own rating; the AI's check is kept beside it as advice.
    func rate(_ rating: String) {
        guard let p = problem else { return }
        do {
            try store.recordAttempt(itemId: p.id, sessionId: session.id, answer: answer, rating: rating, aiFeedback: check?.feedbackMd,
                                    aiVerdict: check?.verdict, durationMs: Int(Date().timeIntervalSince(problemStarted) * 1000))
        } catch { model.fail(error) }
        nextItem(count: progress.problemIds.count)
    }

    // MARK: Explain

    var explainPrompt: String {
        guard let t = topic else { return "" }
        return t.id == session.topicId ? (store.lesson(topicId: t.id)?.explainPrompt ?? "Explain \(t.title) in two or three sentences, in your own words, as if to a classmate.")
                                       : "Explain \(t.title) in two or three sentences, in your own words."
    }

    func askFeedback() {
        guard let t = topic, !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        checking = true; aiError = nil
        let lesson = store.lesson(topicId: t.id)
        let ideas = ([t.summary ?? ""] + t.objectives + (lesson?.sections.filter { $0.kind == "idea" || $0.kind == "summary" }.map(\.bodyMd) ?? [])
                     + (store.notebook(topicId: t.id)?.terms.map { "\($0.term): \($0.definition)" } ?? [])).joined(separator: "\n")
        let text = explanation, title = t.title
        asking += 1
        let ticket = asking
        Task {
            do {
                let r = try await model.ai.inline(.explainFeedback, { try await $0.explainFeedback(topic: title, keyIdeas: ideas, explanation: text) })
                guard ticket == asking else { return }
                checking = false
                guard let r else { aiError = "Feedback needs Everyday AI. Turn it on in Settings › AI."; return }
                feedback = (r.feedbackMd, r.missing)
            } catch {
                guard ticket == asking else { return }
                checking = false
                aiError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func rateExplanation(_ rating: String) {
        guard let t = topic else { return }
        do { try store.recordCheck(topicId: t.id, sessionId: session.id, kind: "explain", rating: rating, answer: explanation, aiFeedback: feedback?.md) }
        catch { model.fail(error) }
        next()
    }

    // MARK: Exam prep

    func rateRecall(_ rating: String) {
        guard let t = topic else { return }
        do { try store.recordCheck(topicId: t.id, sessionId: session.id, kind: "notebook_review", rating: rating) } catch { model.fail(error) }
        nextItem(count: progress.topicIds.count)
    }

    // MARK: Lock in

    func lockIn() {
        if kind == .topic, let t = session.topicId {
            let keep = drafts.filter(\.keep).map { LessonCard(front: $0.front, back: $0.back) }
            if let ids = try? store.keepCards(topicId: t, keep) { progress.cardsKept += ids }
        }
        save()
        finish()
    }
}

struct CardDraft: Identifiable {
    let id = UUID()
    var front: String
    var back: String
    var keep = true
}

struct SessionSummary {
    var topics: [(title: String, before: Mastery, after: Mastery)]
    var cardsReviewed: Int
    var recalled: Int
    var kept: Int
    var next: SessionPick?
}
