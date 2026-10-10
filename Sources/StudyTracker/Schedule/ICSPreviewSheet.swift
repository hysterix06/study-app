import SwiftUI
import StudyCore
import StudyAI

struct ICSPreviewSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var preview: ICSPreview

    var body: some View {
        let plan = preview.plan
        let courses = model.store.courseMap()
        VStack(alignment: .leading, spacing: 14) {
            Text("Import \(preview.name)").font(.stHeading)
            Picker("This calendar is", selection: $preview.role) {
                Text("My school timetable and deadlines").tag("school")
                Text("Busy time (work shifts, personal)").tag("busy")
            }
            .pickerStyle(.radioGroup)
            .onChange(of: preview.role) { replan() }
            Text(plan.summary.capitalizedFirst + ".").font(.stBodyStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !plan.newCourses.isEmpty {
                        SectionHeader(title: "New courses")
                        ForEach(plan.newCourses, id: \.key) { c in Text("\(c.code.map { "\($0) · " } ?? "")\(c.name)").font(.stBody) }
                    }
                    if !plan.patterns.isEmpty {
                        SectionHeader(title: "Weekly classes")
                        ForEach(plan.patterns, id: \.uid) { op in
                            HStack {
                                Text(Calendar.current.weekdaySymbols[op.pattern.weekday % 7]).frame(width: 90, alignment: .leading)
                                Text("\(op.pattern.startTime.string)–\(op.pattern.endTime.string)").monospacedDigit()
                                Text(courseName(op.course, courses: courses, plan: plan))
                                Spacer()
                                Text(op.action.rawValue).foregroundStyle(op.action == .conflict ? Theme.attention : Theme.textSecondary)
                            }.font(.stSmall)
                        }
                    }
                    if !plan.exceptions.isEmpty {
                        Text("\(plan.exceptions.count) canceled or moved class\(plan.exceptions.count == 1 ? "" : "es")").font(.stSmall).foregroundStyle(Theme.textSecondary)
                    }
                    let newEvents = plan.events.filter { $0.action != .unchanged }
                    if !newEvents.isEmpty {
                        SectionHeader(title: preview.role == "busy" ? "Busy times" : "Events")
                        ForEach(newEvents.prefix(12), id: \.event.externalUid) { op in
                            HStack { Text(op.event.title).lineLimit(1); Spacer(); Text(Formatters.dayTime(op.event.start, tz: model.tz)).monospacedDigit() }.font(.stSmall)
                        }
                        if newEvents.count > 12 { Text("and \(newEvents.count - 12) more").font(.stSmall).foregroundStyle(Theme.textTertiary) }
                    }
                    if !plan.assignments.isEmpty {
                        SectionHeader(title: "Deadlines (you'll confirm them in the Inbox)")
                        ForEach(plan.assignments, id: \.assignment.externalUid) { op in
                            HStack { Text(op.assignment.title); Spacer(); Text(Formatters.due(op.assignment.dueAt, tz: model.tz)).monospacedDigit() }.font(.stSmall)
                        }
                    }
                }
            }.frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { model.applyICS(preview) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560)
    }

    func replan() {
        if let plan = try? model.store.planICSImport(text: preview.text, role: preview.role, sourceId: preview.sourceId) { preview.plan = plan }
    }

    func courseName(_ ref: ICSImportPlan.CourseRef, courses: [Int: Course], plan: ICSImportPlan) -> String {
        switch ref {
        case .existing(let id): return courses[id]?.displayName ?? ""
        case .new(let key): return (plan.newCourses.first { $0.key == key }).map { $0.code ?? $0.name } ?? "" + " (new)"
        }
    }
}
