import SwiftUI
import StudyCore
import StudyAI

/// A session takes the whole window: a quiet top bar (where you are, the steps, the time, close), one step at a time,
/// and the step's actions at the bottom. Closing saves; Continue picks it up.
struct SessionView: View {
    @Environment(AppModel.self) var model
    var c: SessionController

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            topBar
            Divider()
            Group {
                if c.step == .done {
                    SessionDone(c: c)
                } else {
                    switch c.step {
                    case .pages: PagesStep(c: c)
                    case .warmup, .cards: CardsStep(c: c)
                    case .learn: LearnStep(c: c)
                    case .practice: PracticeStep(c: c)
                    case .explain: ExplainStep(c: c)
                    case .recall: RecallStep(c: c)
                    case .lockin: LockInStep(c: c)
                    case .done: EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .canvasBackground()
    }

    func openTutor(_ t: PathTopic) {
        do { model.chat = try ChatController.tutor(topicId: t.id, step: c.step, model: model) } catch { model.fail(error) }
    }

    var topBar: some View {
        HStack(spacing: 14) {
            Button { c.close() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction).help("Close (Esc). Your place is saved.")
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.stBodyStrong).lineLimit(1)
                if let course = c.course { Text(course.displayName).font(.stSmall).foregroundStyle(Theme.textTertiary) }
            }
            Spacer()
            if c.progress.steps.count > 1 {
                HStack(spacing: 6) {
                    ForEach(c.progress.steps, id: \.self) { s in
                        let current = s == c.step, past = (c.progress.steps.firstIndex(of: s) ?? 0) < (c.progress.steps.firstIndex(of: c.step) ?? 99) || c.step == .done
                        Text(s.title).font(current ? .stSmallStrong : .stSmall)
                            .foregroundStyle(current ? Theme.textPrimary : past ? Theme.textSecondary : Theme.textTertiary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(current ? Theme.fillSubtle : Theme.clear))
                    }
                }
            }
            Spacer()
            if let t = c.topic, !model.ai.candidates(for: .explainFeedback).isEmpty {
                Button { openTutor(t) } label: { Label("Tutor", systemImage: "bubble.left.and.bubble.right") }
                    .buttonStyle(QuietButtonStyle()).keyboardShortcut("t", modifiers: .command).help("Ask about this topic (⌘T)")
            }
            TimelineView(.periodic(from: c.startedAt, by: 1)) { ctx in
                let s = Int(ctx.date.timeIntervalSince(c.startedAt))
                Text(String(format: "%d:%02d", s / 60, s % 60)).font(.stBody).monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("Time in this session")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }
}

/// The step's content in a readable column, with its actions underneath.
struct StepLayout<Content: View, Actions: View>: View {
    var heading: String?
    var note: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let heading { Text(heading).font(.stHeading) }
                    if let note { Text(note).font(.stBody).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                    content()
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 10) { actions() }
                .padding(.horizontal, 28).padding(.vertical, 12)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Notebook

struct PagesStep: View {
    @Environment(AppModel.self) var model
    @Bindable var c: SessionController

    var body: some View {
        if !model.store.boolSetting("notebook_tips_seen") {
            NotebookTips { model.store.setBool("notebook_tips_seen", true); model.refresh() }
        } else if let t = c.topic {
            let n = c.progress.topicIds.count
            StepLayout(heading: "Page \(c.progress.index + 1) of \(n)",
                       note: "Copy the words and draw the pictures by hand. Short and neat beats complete: this page is what you'll revise from.") {
                LessonKitView(blocks: [LessonKit.page(t, number: c.numbers[t.id] ?? "", guide: model.store.notebook(topicId: t.id), showMark: false)])
            } actions: {
                TextField("Page in your notebook (optional)", text: $c.pageNumber).frame(width: 230).textFieldStyle(.roundedBorder)
                Spacer()
                Button("Not now") { c.nextItem(count: n) }.buttonStyle(QuietButtonStyle())
                Button(c.progress.index + 1 < n ? "Written · next page" : "Written · finish") { c.pageWritten() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Shown once, before the first page: how to set the notebook up.
struct NotebookTips: View {
    var start: () -> Void
    let tips = [
        ("book.closed", "A dotted notebook, just for this course. Keep the first two pages free for the index."),
        ("rectangle.split.2x1", "Start each unit on a new page with its title: a divider page."),
        ("number", "One topic per page, with its number and title at the top (like 2.3 Overbooking)."),
        ("paintpalette", "One colour for the words, another for the pictures."),
        ("pencil.and.outline", "Copy the words, draw the pictures, write the formulas. Don't worry about understanding everything yet: that's what the lessons are for."),
        ("list.number", "Tell the app which page each topic is on, and it keeps the index for you."),
    ]

    var body: some View {
        StepLayout(heading: "Before you start your notebook", note: "Writing the whole course down first, words and pictures, makes it familiar, and shows you it isn't that big.") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(tips, id: \.1) { icon, text in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: icon).frame(width: 22).foregroundStyle(Theme.textSecondary)
                        Text(text).font(.stBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.top, 6)
        } actions: {
            Spacer()
            Button("Start writing") { start() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: Cards

struct CardsStep: View {
    @Bindable var c: SessionController

    var body: some View {
        if let q = c.cards {
            if q.finished || q.cards.isEmpty {
                StepLayout(heading: q.cards.isEmpty ? "No cards due" : "You recalled \(q.recalled) of \(q.ratings.count)",
                           note: q.longer > 0 ? "\(q.longer) card\(q.longer == 1 ? "" : "s") moved to longer intervals." : nil) {
                    EmptyView()
                } actions: {
                    Spacer()
                    Button(c.step == .warmup ? "Continue to the lesson" : "Finish") { c.next() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            } else {
                VStack {
                    if c.step == .warmup {
                        Text("Warm-up: cards due from this course").font(.stSmall).foregroundStyle(Theme.textTertiary).padding(.top, 18)
                    }
                    CardReviewer(queue: q).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: Learn

struct LearnStep: View {
    @Environment(AppModel.self) var model
    var c: SessionController

    var body: some View {
        if let t = c.topic {
            let store = model.store
            let lesson = store.lesson(topicId: t.id)
            let nextTitle = c.progress.steps.drop { $0 != .learn }.dropFirst().first?.title ?? "Finish"
            StepLayout(heading: nil, note: nil) {
                LessonKitView(blocks: blocks(t, lesson: lesson))
            } actions: {
                if lesson == nil {
                    Label("The lesson is being written. Your notebook page and the slides are here meanwhile.", systemImage: "hourglass")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Next: \(nextTitle)") { c.next() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// A glance at the notebook page (the guide, when it isn't written yet), then the lesson; without a lesson, the
    /// course's own slides on the topic.
    func blocks(_ t: PathTopic, lesson: TopicLesson?) -> [[String: Any]] {
        let store = model.store
        var out: [[String: Any]] = [["type": "divider", "text": t.inNotebook ? "Your notebook page\(t.notebookPage.map { " · p. \($0)" } ?? "")" : "Your notebook page: write it first"]]
        out.append(LessonKit.page(t, number: c.numbers[t.id] ?? "", guide: store.notebook(topicId: t.id), showMark: false))
        if let lesson {
            let kinds: Set<String>? = c.mode == .quick ? ["idea", "course_angle"] : nil
            out.append(["type": "divider", "text": "Lesson"])
            out += LessonKit.lesson(lesson, store: store, sections: kinds)
        } else {
            let chunks = store.topicCourseChunks(topicId: t.id, budget: 8_000)
            if !chunks.isEmpty {
                out.append(["type": "divider", "text": "From your course's slides"])
                out += chunks.map { ["type": "markdown", "md": "**\($0.heading ?? $0.locator)** · \($0.locator)\n\n\($0.textMd)"] as [String: Any] }
            }
        }
        return out
    }
}

// MARK: Practice

struct PracticeStep: View {
    @Environment(AppModel.self) var model
    @Bindable var c: SessionController

    var body: some View {
        if let p = c.problem {
            let n = c.progress.problemIds.count
            StepLayout(heading: "Problem \(c.progress.index + 1) of \(n)", note: source(p)) {
                LessonKitView(blocks: [["type": "markdown", "md": p.promptMd]])
                Text("Your answer (or work it out on paper)").font(.stSmall).foregroundStyle(Theme.textTertiary)
                TextEditor(text: $c.answer).font(.stBody).scrollContentBackground(.hidden).frame(minHeight: 110)
                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                ForEach(Array(p.hints.prefix(c.hintsShown).enumerated()), id: \.offset) { _, h in
                    Label(h, systemImage: "lightbulb").font(.stBody).foregroundStyle(Theme.textSecondary)
                }
                if let check = c.check {
                    Panel {
                        HStack {
                            Chip(text: verdictLabel(check.verdict), urgent: check.verdict == "incorrect")
                            Text("Advice only: your rating decides.").font(.stSmall).foregroundStyle(Theme.textTertiary)
                        }
                        LessonKitView(blocks: [["type": "markdown", "md": check.feedbackMd]])
                    }
                }
                if let e = c.aiError { Label(e, systemImage: "exclamationmark.triangle").font(.stSmall).foregroundStyle(Theme.attention) }
                if c.solutionShown, let s = p.solutionMd {
                    Panel {
                        SectionHeader(title: "The course's solution")
                        LessonKitView(blocks: [["type": "markdown", "md": s]])
                    }
                }
            } actions: {
                if c.hintsShown < p.hints.count { Button("Hint") { c.hintsShown += 1 }.buttonStyle(QuietButtonStyle()) }
                if !c.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.ai.candidates(for: .checkAnswer).isEmpty {
                    Button(c.checking ? "Checking…" : "Check my answer") { c.checkAnswer() }.buttonStyle(QuietButtonStyle()).disabled(c.checking)
                }
                if p.solutionMd != nil && !c.solutionShown { Button("Show solution") { c.solutionShown = true }.buttonStyle(QuietButtonStyle()) }
                Spacer()
                Text("How did it go?").font(.stSmall).foregroundStyle(Theme.textTertiary)
                Button("Missed") { c.rate("missed") }.buttonStyle(QuietButtonStyle())
                Button("Partly") { c.rate("partly") }.buttonStyle(QuietButtonStyle())
                Button("Got it") { c.rate("got") }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    func source(_ p: PracticeItem) -> String {
        guard p.source == "course", let m = p.materialId.flatMap({ model.store.material($0) }) else { return "Practice problem" }
        var s = "From \(m.title)"
        if let n = p.number { s += ", question \(n)" }
        if p.examStyle { s += " · exam style" }
        if let marks = p.marks { s += " · \(Formatters.hours(marks).replacingOccurrences(of: " h", with: "")) marks" }
        return s
    }

    func verdictLabel(_ v: String) -> String {
        ["correct": "Looks right", "partly": "Partly there", "incorrect": "Not yet", "unsure": "Can't tell"][v] ?? v
    }
}

// MARK: Explain

struct ExplainStep: View {
    @Environment(AppModel.self) var model
    @Bindable var c: SessionController

    var body: some View {
        StepLayout(heading: "Explain it back", note: c.explainPrompt) {
            TextEditor(text: $c.explanation).font(.stBody).scrollContentBackground(.hidden).frame(minHeight: 140)
                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            Text("Two or three sentences, in your own words, without looking.").font(.stSmall).foregroundStyle(Theme.textTertiary)
            if let f = c.feedback {
                Panel {
                    LessonKitView(blocks: [["type": "markdown", "md": f.md + (f.missing.isEmpty ? "" : "\n\n**Left out:** " + f.missing.joined(separator: "; "))]])
                    Text("Advice only: your rating decides.").font(.stSmall).foregroundStyle(Theme.textTertiary)
                }
            }
            if let e = c.aiError { Label(e, systemImage: "exclamationmark.triangle").font(.stSmall).foregroundStyle(Theme.attention) }
        } actions: {
            if !c.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.ai.candidates(for: .explainFeedback).isEmpty {
                Button(c.checking ? "Reading…" : "Get feedback") { c.askFeedback() }.buttonStyle(QuietButtonStyle()).disabled(c.checking)
            }
            Spacer()
            Text("How well did you explain it?").font(.stSmall).foregroundStyle(Theme.textTertiary)
            Button("Not yet") { c.rateExplanation("not_yet") }.buttonStyle(QuietButtonStyle())
            Button("Mostly") { c.rateExplanation("mostly") }.buttonStyle(QuietButtonStyle())
            Button("Nailed it") { c.rateExplanation("nailed") }.buttonStyle(PrimaryButtonStyle())
        }
    }
}

// MARK: Exam prep

struct RecallStep: View {
    @Environment(AppModel.self) var model
    @Bindable var c: SessionController

    var body: some View {
        if let t = c.topic {
            let n = c.progress.topicIds.count
            StepLayout(heading: "Topic \(c.progress.index + 1) of \(n): \(c.numbers[t.id] ?? "") \(t.title)",
                       note: c.pageShown ? "Check what you recalled against the page." :
                        "Cover \(t.notebookPage.map { "page \($0)" } ?? "this topic's page") in your notebook. Say the words out loud and redraw the pictures, then check.") {
                if c.pageShown {
                    LessonKitView(blocks: [LessonKit.page(t, number: c.numbers[t.id] ?? "", guide: model.store.notebook(topicId: t.id), showMark: false)])
                }
            } actions: {
                Spacer()
                if c.pageShown {
                    Text("How was it?").font(.stSmall).foregroundStyle(Theme.textTertiary)
                    Button("Shaky") { c.rateRecall("shaky") }.buttonStyle(QuietButtonStyle())
                    Button("Solid") { c.rateRecall("solid") }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Show the page") { c.pageShown = true }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: Lock in

struct LockInStep: View {
    @Bindable var c: SessionController

    var body: some View {
        StepLayout(heading: "Lock it in", note: c.drafts.isEmpty ? "Add the cards worth remembering: definitions, formulas, key facts."
                                                                   : "These cards go into your reviews. Untick or rewrite any; cards in your own words stick better.") {
            ForEach($c.drafts) { $d in
                HStack(alignment: .top, spacing: 10) {
                    Toggle("", isOn: $d.keep).labelsHidden().toggleStyle(.checkbox).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Question", text: $d.front).textFieldStyle(.roundedBorder).font(.stBodyStrong)
                        TextField("Answer", text: $d.back, axis: .vertical).textFieldStyle(.roundedBorder).font(.stBody)
                    }
                    .opacity(d.keep ? 1 : 0.45)
                }
            }
            Button("Add a card") { c.drafts.append(CardDraft(front: "", back: "")) }.buttonStyle(QuietButtonStyle())
        } actions: {
            Spacer()
            Button("Finish") { c.lockIn() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: Done

/// Peak-end: a specific, positive summary, how each topic moved, and the next session.
struct SessionDone: View {
    @Environment(AppModel.self) var model
    var c: SessionController

    var body: some View {
        let s = c.summary
        StepLayout(heading: "Session done", note: c.summaryLine) {
            if let s {
                ForEach(Array(s.topics.enumerated()), id: \.offset) { _, t in
                    HStack {
                        Text(t.title).font(.stBody)
                        Spacer()
                        if t.before != t.after {
                            Text(t.before.label).font(.stSmall).foregroundStyle(Theme.textTertiary)
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        }
                        Chip(text: t.after.label)
                    }
                }
                if s.kept > 0 { Text("\(s.kept) card\(s.kept == 1 ? "" : "s") added to your reviews.").font(.stBody).foregroundStyle(Theme.textSecondary) }
                if s.cardsReviewed > 0 { Text("You recalled \(s.recalled) of \(s.cardsReviewed) cards.").font(.stBody).foregroundStyle(Theme.textSecondary) }
            }
        } actions: {
            if let next = s?.next {
                Text("Next: \(SessionCopy.describe(next, store: model.store))").font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                Button("Done") { c.close() }.buttonStyle(QuietButtonStyle())
                Button("Start next") { c.close(); model.startSession(next) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Done") { c.close() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// How a suggested session reads: "Notebook · HM210 Unit 2 (3 pages)", "2.3 Overbooking".
enum SessionCopy {
    @MainActor
    static func describe(_ p: SessionPick, store: StudyStore) -> String {
        let course = p.courseId.flatMap { store.course($0) }?.displayName ?? ""
        if p.sessionId != nil { return "Continue · " + describe(SessionPick(kind: p.kind, courseId: p.courseId, topicId: p.topicId, assignmentId: p.assignmentId,
                                                                             topicIds: p.topicIds, minutes: p.minutes, score: p.score), store: store) }
        switch p.kind {
        case .notebook: return "Notebook · \(course) (\(p.topicIds.count) page\(p.topicIds.count == 1 ? "" : "s"))"
        case .review: return "Review your cards"
        case .examPrep: return "Exam prep · \(p.assignmentId.flatMap { store.assignment($0) }?.title ?? course)"
        case .topic:
            guard let t = p.topicId.flatMap({ store.topic($0) }) else { return course }
            return "\(course) · \(store.topicNumbers(courseId: t.courseId)[t.id].map { "\($0) " } ?? "")\(t.title)"
        }
    }
}
