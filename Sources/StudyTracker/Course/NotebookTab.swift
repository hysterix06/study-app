import SwiftUI
import AppKit
import StudyCore

/// The whole course on one page, as the student writes it into a dotted notebook: per topic, the words, the pictures
/// and the formulas. Its size is stated up front, because a swamped student needs to see the course isn't that big.
struct NotebookTab: View {
    @Environment(AppModel.self) var model
    var course: Course
    @State private var showIndex = false

    var body: some View {
        let _ = model.revision
        let store = model.store
        let topics = store.topics(courseId: course.id).filter { $0.userState != "hidden" }
        let pages = store.notebooks(courseId: course.id)
        let numbers = store.topicNumbers(courseId: course.id)
        if topics.isEmpty {
            EmptyState(text: "The notebook guide follows the course's path, which appears once the course has lectures.")
        } else {
            let minutes = topics.reduce(0) { $0 + (pages[$1.id]?.writingMinutes ?? 5) }
            let written = topics.filter(\.inNotebook).count
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The whole course: \(topics.count) pages · about \(duration(minutes)) to write").font(.stHeading)
                        Text(written == 0 ? "Write it start to finish: the words and pictures first, before learning each topic properly."
                                          : "\(written) of \(topics.count) pages written.")
                            .font(.stSmall).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if let unwritten = nextPages(topics) {
                        Button("Write next pages") { model.startSession(SessionPick(kind: .notebook, courseId: course.id, topicIds: unwritten, minutes: 25, score: 1)) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    Button(showIndex ? "Show pages" : "Index") { showIndex.toggle() }.buttonStyle(QuietButtonStyle())
                    Button("Print or PDF…") { printGuide() }.buttonStyle(QuietButtonStyle())
                }
                if showIndex {
                    NotebookIndex(topics: topics, numbers: numbers)
                } else {
                    LessonKitView(blocks: guideBlocks(topics: topics, numbers: numbers, pages: pages, actions: true)) { name, id in
                        guard let t = topics.first(where: { $0.id == id }) else { return }
                        NotebookMarking.ask(topic: t, model: model, change: name == "unmark")
                    }
                }
            }
        }
    }

    /// The whole guide in path order, with a divider for each unit.
    func guideBlocks(topics: [PathTopic], numbers: [Int: String], pages: [Int: TopicNotebook], actions: Bool) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for (i, unit) in model.store.units(courseId: course.id).enumerated() {
            let mine = topics.filter { $0.unitId == unit.id }
            guard !mine.isEmpty else { continue }
            blocks.append(["type": "divider", "text": "Unit \(i + 1) · \(unit.title)"])
            blocks += mine.map { LessonKit.page($0, number: numbers[$0.id] ?? "", guide: pages[$0.id], showMark: actions, markAction: actions) }
        }
        return blocks
    }

    /// The unit the student is writing: the first one with pages left, in path order.
    func nextPages(_ topics: [PathTopic]) -> [Int]? {
        for unit in model.store.units(courseId: course.id) {
            let left = topics.filter { $0.unitId == unit.id && !$0.inNotebook }.map(\.id)
            if !left.isEmpty { return left }
        }
        return nil
    }

    func printGuide() {
        let store = model.store
        let topics = store.topics(courseId: course.id).filter { $0.userState != "hidden" }
        let blocks = [["type": "markdown", "md": "# \(course.name)\n\nThe notebook guide: \(topics.count) pages."] as [String: Any]]
            + guideBlocks(topics: topics, numbers: store.topicNumbers(courseId: course.id), pages: store.notebooks(courseId: course.id), actions: false)
        LessonKitPrinter.shared.print(blocks, title: "\(course.codeOrName) notebook guide")
    }

    func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes % 60 < 8 ? "\(minutes / 60) h" : minutes % 60 > 52 ? "\(minutes / 60 + 1) h" : "\(minutes / 60)½ h"
    }
}

/// What to copy into the front of the notebook: every topic and the page it's on.
struct NotebookIndex: View {
    var topics: [PathTopic]
    var numbers: [Int: String]
    var body: some View {
        Panel {
            SectionHeader(title: "Index")
            ForEach(topics) { t in
                HStack {
                    Text(numbers[t.id] ?? "").monospacedDigit().foregroundStyle(Theme.textTertiary).frame(width: 34, alignment: .trailing)
                    Text(t.title)
                    Spacer()
                    Text(t.notebookPage.map { "p. \($0)" } ?? (t.inNotebook ? "written" : "")).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }.font(.stBody)
            }
        }
    }
}

/// The student's own mark that a page is written, and on which page of their notebook.
enum NotebookMarking {
    @MainActor
    static func ask(topic: PathTopic, model: AppModel, change: Bool) {
        let alert = NSAlert()
        alert.messageText = change ? "\(topic.title): written" : "Mark “\(topic.title)” as written?"
        alert.informativeText = "Which page of your notebook is it on? (optional; it goes in the index)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 14"
        field.stringValue = topic.notebookPage ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: change ? "Save" : "Written")
        alert.addButton(withTitle: "Cancel")
        if change { alert.addButton(withTitle: "Not written yet") }
        alert.window.initialFirstResponder = field
        let answer = alert.runModal()
        do {
            switch answer {
            case .alertFirstButtonReturn:
                try model.store.setNotebookWritten(topic.id, written: true, page: field.stringValue.trimmingCharacters(in: .whitespaces))
            case .alertThirdButtonReturn:
                try model.store.setNotebookWritten(topic.id, written: false)
            default: return
            }
            model.refresh()
        } catch { model.fail(error) }
    }
}
