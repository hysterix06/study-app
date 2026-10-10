import SwiftUI
import StudyCore

/// What earns marks in this course: what the course builder found it emphasises and how it grades, where past exams
/// give their marks, the kinds of questions they ask, and the topics the course stresses most.
struct AnglesTab: View {
    @Environment(AppModel.self) var model
    var course: Course

    var body: some View {
        let _ = model.revision
        let store = model.store
        let path = store.path(courseId: course.id)
        let topics = store.topics(courseId: course.id)
        let numbers = store.topicNumbers(courseId: course.id)
        let examFiles = store.materials(courseId: course.id).filter { $0.group == .exams }
        let examItems = examFiles.flatMap { store.practiceItems(materialId: $0.id) }
        VStack(alignment: .leading, spacing: 22) {
            if let angles = path?.anglesMd?.nilIfEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "How this course grades")
                    LessonKitView(blocks: [["type": "markdown", "md": angles]])
                }
            }
            let marks = marksByTopic(examItems, topics: topics)
            if !marks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Where past exams give marks")
                    let top = marks.map(\.marks).max() ?? 1
                    ForEach(marks, id: \.title) { m in
                        HStack(spacing: 10) {
                            Text(m.title).font(.stBody).frame(width: 260, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3).fill(Theme.course(course.color))
                                    .frame(width: max(4, g.size.width * m.marks / max(top, 1)))
                            }.frame(height: 10)
                            Text(m.marks == m.marks.rounded() ? "\(Int(m.marks))" : String(format: "%.1f", m.marks)).font(.stSmall).monospacedDigit()
                                .foregroundStyle(Theme.textSecondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                    Text("From \(examFiles.count) past exam\(examFiles.count == 1 ? "" : "s"): \(examFiles.map(\.title).joined(separator: ", ")).")
                        .font(.stSmall).foregroundStyle(Theme.textTertiary)
                }
            }
            let kinds = Dictionary(grouping: examItems.filter { $0.kind != "other" }, by: \.kind).mapValues(\.count).sorted { $0.value > $1.value }
            if !kinds.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "What its exams ask")
                    HStack(spacing: 8) {
                        ForEach(kinds, id: \.key) { k, n in Chip(text: "\(Self.kindLabel(k)) · \(n)") }
                    }
                }
            }
            let stressed = topics.filter { $0.emphasis >= 2 }.sorted { $0.emphasis > $1.emphasis }
            if !stressed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "What the course stresses")
                    ForEach(stressed) { t in
                        Button { model.go(.topic(t.id)) } label: {
                            HStack {
                                Text("\(numbers[t.id] ?? "") \(t.title)").font(.stBody)
                                Spacer()
                                Chip(text: t.emphasis >= 3 ? "Exam-critical" : "Stressed in class")
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if path?.anglesMd == nil && examItems.isEmpty && stressed.isEmpty {
                EmptyState(text: "Angles come from the course's syllabus, its past exams and what its lectures stress. Add them to Files, or build the course with Claude.")
            }
        }
    }

    /// Marks per topic: by the path topic a question is linked to, else its label.
    func marksByTopic(_ items: [PracticeItem], topics: [PathTopic]) -> [(title: String, marks: Double)] {
        var out: [String: Double] = [:]
        let byId = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0.title) })
        for i in items {
            let title = i.topicId.flatMap { byId[$0] } ?? i.topicLabel ?? "Other"
            out[title, default: 0] += i.marks ?? 1
        }
        let rows: [(title: String, marks: Double)] = out.map { (title: $0.key, marks: $0.value) }
        return Array(rows.sorted { $0.marks > $1.marks }.prefix(12))
    }

    static func kindLabel(_ k: String) -> String {
        ["calculate": "Calculations", "short": "Short answers", "explain": "Explanations", "apply": "Apply to a case", "compare": "Comparisons",
         "mcq": "Multiple choice", "essay": "Essays", "proof": "Proofs", "case": "Case studies"][k] ?? k.capitalized
    }
}
