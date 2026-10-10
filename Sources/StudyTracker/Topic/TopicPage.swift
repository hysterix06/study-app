import SwiftUI
import StudyCore

/// One topic: where it sits in the path, how well it's known, its notebook page and lesson, where the course teaches it,
/// and its problems. Start studying it from here.
struct TopicPage: View {
    @Environment(AppModel.self) var model
    var topicId: Int

    var body: some View {
        let _ = model.revision
        let store = model.store
        if let t = store.topic(topicId) {
            let number = store.topicNumbers(courseId: t.courseId)[t.id] ?? ""
            let lesson = store.lesson(topicId: t.id)
            let practice = store.practiceItems(topicId: t.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(number)  \(t.title)").font(.stTitle)
                        HStack(spacing: 8) {
                            Chip(text: t.mastery.label)
                            if t.emphasis >= 3 { Chip(text: "Exam-critical") }
                            if let p = t.notebookPage { Chip(text: "Notebook p. \(p)", systemImage: "book.closed") }
                            if t.beyondCourse { Chip(text: "Background, not examined") }
                            if t.retired { Chip(text: "No longer in the path") }
                        }
                        if let s = t.summary { Text(s).font(.stBody).foregroundStyle(Theme.textSecondary) }
                        if !t.objectives.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(t.objectives, id: \.self) { Text("• \($0)").font(.stBody) }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Study this now") { model.startSession(SessionPick(kind: .topic, courseId: t.courseId, topicId: t.id, minutes: 25, score: 1)) }
                            .buttonStyle(PrimaryButtonStyle())
                        if !t.inNotebook {
                            Button("Write its page") { model.startSession(SessionPick(kind: .notebook, courseId: t.courseId, topicIds: [t.id], minutes: 10, score: 1)) }
                                .buttonStyle(QuietButtonStyle())
                        }
                        Spacer()
                        Menu("More") {
                            if t.userState == nil {
                                Button("I know this") { set(t, "known") }
                                Button("Hide") { set(t, "hidden") }
                            } else {
                                Button("Bring back") { set(t, nil) }
                            }
                        }.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Notebook page")
                        NotebookPageView(topic: t, number: number, guide: store.notebook(topicId: t.id))
                    }
                    if let lesson {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Lesson")
                            LessonKitView(blocks: LessonKit.lesson(lesson, store: store))
                        }
                    }
                    let sources = store.coverage(topicId: t.id)
                    if !sources.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "Where your course teaches it")
                            ForEach(sources, id: \.materialId) { c in
                                if let m = store.material(c.materialId) {
                                    Button { model.openMaterial(m.id) } label: {
                                        HStack {
                                            Image(systemName: "doc").foregroundStyle(Theme.textTertiary)
                                            Text(m.title).font(.stBody)
                                            Spacer()
                                            if !c.chunkIds.isEmpty {
                                                Text(store.chunks(ids: Array(c.chunkIds.prefix(4))).map(\.locator).joined(separator: ", "))
                                                    .font(.stSmall).foregroundStyle(Theme.textTertiary)
                                            }
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !practice.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "Practice · \(practice.count) problem\(practice.count == 1 ? "" : "s")")
                            ForEach(practice.prefix(8)) { p in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(String(p.promptMd.replacingOccurrences(of: "\n", with: " ").prefix(140))).font(.stBody).lineLimit(2)
                                    Spacer()
                                    if let m = p.materialId.flatMap({ store.material($0) }) { Text(m.title).font(.stSmall).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                                }
                            }
                        }
                    }
                }
                .padding(28).contentWidth()
            }
        } else {
            EmptyState(text: "This topic is no longer in the path.")
        }
    }

    func set(_ t: PathTopic, _ state: String?) {
        do { try model.store.setTopicUserState(t.id, state); model.refresh() } catch { model.fail(error) }
    }
}
