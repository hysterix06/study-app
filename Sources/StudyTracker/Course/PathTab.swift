import SwiftUI
import StudyCore

/// The course as a path: units of numbered topics in the order to learn them, each with how well it's known. Who
/// built it is stated, and a basic version offers the course builder.
struct PathTab: View {
    @Environment(AppModel.self) var model
    var course: Course

    var body: some View {
        let _ = model.revision
        let store = model.store
        if let path = store.path(courseId: course.id) {
            let topics = store.topics(courseId: course.id)
            let numbers = store.topicNumbers(courseId: course.id)
            let taught = store.taughtDates(courseId: course.id)
            VStack(alignment: .leading, spacing: 20) {
                BuilderStatus(course: course, path: path)
                if let next = store.nextSessionPlan(courseId: course.id).primary {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next in this course").font(.stSmall).foregroundStyle(Theme.textTertiary)
                            Text(SessionCopy.describe(next, store: store)).font(.stBodyStrong)
                        }
                        Spacer()
                        Button("Start") { model.startSession(next) }.buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(14).background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surface))
                }
                if let approach = path.approachMd?.nilIfEmpty {
                    Panel {
                        SectionHeader(title: "How to learn it")
                        Text(inlineMarkdown(approach)).font(.stBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(store.units(courseId: course.id).enumerated()), id: \.element.id) { i, unit in
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Unit \(i + 1) · \(unit.title)")
                        if let s = unit.summary { Text(s).font(.stSmall).foregroundStyle(Theme.textSecondary) }
                        ForEach(topics.filter { $0.unitId == unit.id }) { t in
                            TopicRow(topic: t, number: numbers[t.id] ?? "", taught: taught[t.id])
                        }
                    }
                }
            }
        } else {
            EmptyState(text: "This course gets its path as soon as it has lectures: add files, or connect Moodle.")
        }
    }
}

/// Who built the path, what the course builder is doing now, and the way to a fuller version.
struct BuilderStatus: View {
    @Environment(AppModel.self) var model
    var course: Course
    var path: CoursePath

    var body: some View {
        let store = model.store
        let active = store.activeJobs().first { $0.task.isCourseBuilding && $0.courseId == course.id }
        let builder = !model.ai.candidates(for: .buildPath).isEmpty
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(path.tierLabel + (path.tier == "full" ? path.builtWith.map { " · \($0)" } ?? "" : "")).font(.stBodyStrong)
                if let active {
                    Text(model.jobs.running["builder"] == active.id ? (model.jobs.statusLine ?? active.label) : "\(active.label): waiting its turn")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                } else if path.stale {
                    Text("New course files arrived; the path updates once they've all come in.").font(.stSmall).foregroundStyle(Theme.textSecondary)
                } else if path.tier == "skeleton" {
                    Text("One topic per lecture, in the order they were taught. Turn on AI in Settings for a real path.")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if active?.task.engineLane != .builder && store.nextBuilderStep(courseId: course.id, tier: "full") != nil {
                if builder && path.tier != "full" {
                    Button("Build with Claude") { model.jobs.buildWithBuilder(courseId: course.id) }.buttonStyle(QuietButtonStyle())
                        .help("The course builder lays the course out again and writes its notebook guide and lessons.")
                } else if !builder {
                    Menu(path.tier == "full" ? "Continue with Claude" : "Build with Claude") {
                        Button("Copy for Claude.ai…") { model.jobs.buildByHand(courseId: course.id, inAIApp: false) }
                        if let app = model.ai.handoffApp { Button("Open in \(app.name)") { model.jobs.buildByHand(courseId: course.id, inAIApp: true) } }
                    }
                    .menuStyle(.button).buttonStyle(QuietButtonStyle()).fixedSize()
                    .help("Free AI built this version. Claude can lay the course out properly and write the notebook guide with drawings.")
                }
            }
        }
    }
}

struct TopicRow: View {
    @Environment(AppModel.self) var model
    var topic: PathTopic
    var number: String
    var taught: LocalDate?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).font(.stBody).monospacedDigit().foregroundStyle(Theme.textTertiary).frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title).font(.stBody).foregroundStyle(topic.isSkipped ? Theme.textTertiary : Theme.textPrimary)
                if let s = topic.summary { Text(s).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if topic.emphasis >= 3 { Chip(text: "Exam-critical") }
            if let taught, taught <= LocalDate(Date(), tz: model.tz) { Chip(text: "Taught \(Formatters.day(taught.at(LocalTime(hour: 12, minute: 0), tz: model.tz), tz: model.tz))") }
            if let p = topic.notebookPage { Chip(text: "p. \(p)", systemImage: "book.closed") }
            if topic.userState == "known" { Chip(text: "You know this") }
            else if topic.userState == "hidden" { Chip(text: "Hidden") }
            else if topic.mastery != .new { Chip(text: topic.mastery.label) }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.surface))
        .contextMenu {
            Button("Study this now") { model.startSession(SessionPick(kind: .topic, courseId: topic.courseId, topicId: topic.id, minutes: 25, score: 1)) }
            Divider()
            if topic.userState == nil {
                Button("I know this") { set("known") }
                Button("Hide") { set("hidden") }
            } else {
                Button("Bring back") { set(nil) }
            }
        }
    }

    func set(_ state: String?) {
        do { try model.store.setTopicUserState(topic.id, state); model.refresh() } catch { model.fail(error) }
    }
}

/// Bullets and emphasis from the course builder, kept to what SwiftUI text shows well.
func inlineMarkdown(_ s: String) -> AttributedString {
    let bulleted = s.replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "•  ", options: .regularExpression)
    return (try? AttributedString(markdown: bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(bulleted)
}

/// LaTeX as readable plain text until the lesson renderer draws it properly: "\\frac{a}{b}" → "a ⁄ b", "\\times" → "×".
func plainMath(_ latex: String) -> String {
    var s = latex
    for (from, to) in [(#"\\text\{([^{}]*)\}"#, "$1"), (#"\\mathrm\{([^{}]*)\}"#, "$1"), (#"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, "($1) ⁄ ($2)"),
                       (#"\\sqrt\{([^{}]*)\}"#, "√($1)"), (#"\^\{([^{}]*)\}"#, "^$1"), (#"_\{([^{}]*)\}"#, "_$1")] {
        s = s.replacingOccurrences(of: from, with: to, options: .regularExpression)
    }
    let symbols: KeyValuePairs = ["\\rightarrow": "→", "\\times": "×", "\\cdot": "·", "\\div": "÷", "\\leq": "≤", "\\geq": "≥", "\\neq": "≠", "\\approx": "≈", "\\pm": "±",
                   "\\sum": "Σ", "\\Delta": "Δ", "\\alpha": "α", "\\beta": "β", "\\sigma": "σ", "\\mu": "μ", "\\pi": "π", "\\infty": "∞",
                   "\\left": "", "\\right": "", "\\,": " ", "\\%": "%"]
    for (k, v) in symbols { s = s.replacingOccurrences(of: k, with: v) }   // in order: \\rightarrow before \\right
    return s.replacingOccurrences(of: #"\(([A-Za-z0-9.]+)\)"#, with: "$1", options: .regularExpression)
}
