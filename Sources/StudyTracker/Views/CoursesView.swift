import SwiftUI
import StudyCore

/// A course is a sidebar row; its page is reached by `course/{id}/{tab}`.
struct CourseScreen: View {
    @Environment(AppModel.self) var model
    var courseId: Int

    var body: some View {
        let _ = model.revision
        if let c = model.store.course(courseId) {
            CourseDetail(course: c, onEdit: { model.courseEditor = c }).id(c.id)
        } else {
            EmptyState(text: "Add your courses, or import a timetable and they appear here.", actionTitle: "Add course") { model.newCourse() }
        }
    }
}

struct CourseDetail: View {
    @Environment(AppModel.self) var model
    var course: Course
    var onEdit: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CourseDot(color: course.color, size: 12)
                Text(course.name).font(.stTitle)
                if let code = course.code { Text(code).font(.stHeading).foregroundStyle(Theme.textTertiary) }
                Spacer()
                Button("Edit") { onEdit() }.buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 24).padding(.top, 20)
            if let i = course.instructor { Text(i).font(.stBody).foregroundStyle(Theme.textSecondary).padding(.horizontal, 24) }
            Picker("", selection: $model.courseTab) { ForEach(CourseTab.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 620)
            Divider()
            ScrollView {
                Group {
                    switch model.courseTab {
                    case .path: PathTab(course: course)
                    case .notebook: NotebookTab(course: course)
                    case .angles: AnglesTab(course: course)
                    case .files: FilesTab(course: course)
                    case .deadlines: CourseDeadlines(course: course)
                    }
                }.padding(24).contentWidth()
            }
        }
    }
}

// MARK: Assignments

/// The course's assignments, same rows as the Assignments screen; each opens its assignment.
struct CourseAssignments: View {
    @Environment(AppModel.self) var model
    var course: Course

    var body: some View {
        let _ = model.revision
        let store = model.store
        let all = store.assignments(AssignmentFilter(courseId: course.id))
        let open = all.filter { $0.isOpen }
        let closed = all.filter { !$0.isOpen }
        let courses = store.courseMap()
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Open")
                if open.isEmpty { Text("Nothing open for this course.").font(.stBody).foregroundStyle(Theme.textSecondary) }
                ForEach(open) { a in
                    Button { model.openAssignment(a.id) } label: { AssignmentLine(a: a, courses: courses) }.buttonStyle(.plain)
                }
            }
            if !closed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Done")
                    ForEach(closed) { a in
                        Button { model.openAssignment(a.id) } label: { AssignmentLine(a: a, courses: courses) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: Deadlines

/// The course's grade, its deadlines and exams, and its class times.
struct CourseDeadlines: View {
    @Environment(AppModel.self) var model
    var course: Course
    @State private var addingPattern = false
    @State private var editPattern: ClassPattern?

    var body: some View {
        let _ = model.revision
        let store = model.store
        VStack(alignment: .leading, spacing: 22) {
            GradeCard(course: course)
            CourseAssignments(course: course)
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Class times", trailing: AnyView(Button("Add class time") { addingPattern = true }.buttonStyle(.borderless).font(.stSmall)))
                let patterns = store.patterns(courseId: course.id)
                if patterns.isEmpty { Text("No weekly classes yet.").font(.stBody).foregroundStyle(Theme.textSecondary) }
                ForEach(patterns) { p in
                    HStack {
                        Text(weekdayName(p.weekday)).frame(width: 90, alignment: .leading)
                        Text("\(p.startTime.string)–\(p.endTime.string)").monospacedDigit()
                        if let l = p.location { Text(l).foregroundStyle(Theme.textSecondary) }
                        Spacer()
                        Text("\(p.validFrom.string) → \(p.validTo.string)").font(.stSmall).foregroundStyle(Theme.textTertiary).monospacedDigit()
                        Button("Edit") { editPattern = p }.buttonStyle(.borderless).font(.stSmall)
                    }.font(.stBody).padding(8).background(RoundedRectangle(cornerRadius: Theme.corner(6)).fill(Theme.fillSubtle))
                }
            }
        }
        .sheet(isPresented: $addingPattern) {
            PatternEditor(pattern: ClassPattern(courseId: course.id, weekday: 1, startTime: LocalTime(hour: 9, minute: 0), endTime: LocalTime(hour: 10, minute: 30),
                                                validFrom: store.currentTerm()?.startDate ?? LocalDate.today(), validTo: store.currentTerm()?.endDate ?? LocalDate.today().adding(days: 100),
                                                timezone: store.timezone.identifier))
        }
        .sheet(item: $editPattern) { p in PatternEditor(pattern: p) }
    }

    func weekdayName(_ w: Int) -> String { Calendar.current.weekdaySymbols[w % 7] }
}

struct GradeCard: View {
    @Environment(AppModel.self) var model
    var course: Course
    var body: some View {
        let result = Result { try model.store.gradeSummary(courseId: course.id) }
        Panel {
            SectionHeader(title: "Grade")
            switch result {
            case .failure(let error):
                Text(String(describing: error)).font(.stSmall).foregroundStyle(Theme.attention)
            case .success(let s):
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(s.currentOnScale.map { course.gradeScale.format($0) } ?? "—").font(.stTitle).monospacedDigit()
                    if let t = course.targetGrade { Text("Target \(course.gradeScale.format(t))").font(.stBody).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                }
                Text(s.headline).font(.stBodyStrong)
                    .foregroundStyle(s.state == .unreachable || s.state == .componentFailed ? Theme.attention : Theme.textPrimary)
                if s.totalWeight > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Theme.corner(3)).fill(Theme.fillSubtle)
                            RoundedRectangle(cornerRadius: Theme.corner(3)).fill(Theme.course(course.color))
                                .frame(width: g.size.width * min(1, s.earned / max(s.totalWeight, 1)))
                            if let t = s.targetPercent {
                                Rectangle().fill(Color.primary).frame(width: 2).offset(x: g.size.width * min(1, t / 100))
                            }
                        }
                    }
                    .frame(height: 8)
                    .accessibilityLabel("Earned \(Int(s.earned)) of \(Int(s.totalWeight)) points")
                    if s.gradedWeight > 0 {
                    Text("Earned \(String(format: "%.1f", s.earned)) of \(String(format: "%g", s.gradedWeight)) graded points · \(String(format: "%g", s.remainingWeight)) points still open")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    }
                }
                if let w = s.weightWarning { Label(w, systemImage: "info.circle").font(.stSmall).foregroundStyle(Theme.textSecondary) }
                ForEach(s.pendingMinimums, id: \.id) { p in
                    Label("\(p.title) needs at least \(Formatters.percent(p.minPct)) to pass.", systemImage: "exclamationmark.circle").font(.stSmall)
                }
                if course.targetGrade == nil {
                    Text("Set a target grade with Edit to see what you need on the remaining work.").font(.stSmall).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

// MARK: Materials

// MARK: Concepts

// MARK: Notes and sheets

// MARK: Cards

// MARK: Editors

struct CourseEditor: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var course: Course
    @State private var target = ""
    @State private var pass = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(course.id == 0 ? "New course" : "Edit course").font(.stHeading)
            Form {
                TextField("Code", text: Binding(get: { course.code ?? "" }, set: { course.code = $0 }), prompt: Text("HM210"))
                TextField("Name", text: $course.name, prompt: Text("Hospitality Financial Accounting"))
                TextField("Short name", text: Binding(get: { course.shortName ?? "" }, set: { course.shortName = $0 }), prompt: Text("Accounting"))
                TextField("Instructor", text: Binding(get: { course.instructor ?? "" }, set: { course.instructor = $0 }))
                TextField("Other names (comma separated)", text: Binding(get: { course.aliases ?? "" }, set: { course.aliases = $0 }), prompt: Text("revman, RM"))
                Picker("Type", selection: $course.kind) {
                    ForEach(["lecture", "practical", "seminar", "placement", "online"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Term", selection: $course.termId) { ForEach(model.store.terms()) { t in Text(t.name).tag(t.id) } }
                Picker("Color", selection: $course.color) {
                    ForEach(CoursePalette.allCases, id: \.rawValue) { p in HStack { CourseDot(color: p.rawValue); Text(p.rawValue.capitalized) }.tag(p.rawValue) }
                }
                Picker("Grading scale", selection: $course.gradeScale) { ForEach(GradeScale.allCases) { Text($0.label).tag($0) } }
                TextField("Target grade (\(course.gradeScale.label))", text: $target)
                TextField("Pass mark (\(course.gradeScale.label))", text: $pass)
                Toggle("Archived", isOn: $course.archived)
            }.formStyle(.grouped)
            HStack {
                if course.id != 0 {
                    Button("Delete course", role: .destructive) {
                        let name = course.name
                        model.run("Deleted \(name).") { try model.store.trashCourse(course.id) }
                        model.go(.home, replace: true)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    course.targetGrade = Double(target.replacingOccurrences(of: ",", with: "."))
                    course.passMark = Double(pass.replacingOccurrences(of: ",", with: "."))
                    do {
                        let id = try model.store.saveCourse(course)
                        model.refresh()
                        model.openCourse(id)
                        dismiss()
                    } catch { model.fail(error) }
                }.buttonStyle(PrimaryButtonStyle()).disabled(course.name.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { target = course.targetGrade.map { String(format: "%g", $0) } ?? ""; pass = course.passMark.map { String(format: "%g", $0) } ?? "" }
    }
}

struct PatternEditor: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var pattern: ClassPattern
    @State private var start = Date()
    @State private var end = Date()
    @State private var from = Date()
    @State private var to = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pattern.id == 0 ? "Add class time" : "Edit class time").font(.stHeading)
            Form {
                Picker("Day", selection: $pattern.weekday) { ForEach(1...7, id: \.self) { w in Text(Calendar.current.weekdaySymbols[w % 7]).tag(w) } }
                DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                TextField("Room", text: Binding(get: { pattern.location ?? "" }, set: { pattern.location = $0.isEmpty ? nil : $0 }))
                DatePicker("First class", selection: $from, displayedComponents: .date)
                DatePicker("Last class", selection: $to, displayedComponents: .date)
            }.formStyle(.grouped).environment(\.timeZone, pattern.tz)
            HStack {
                if pattern.id != 0 {
                    Button("Remove", role: .destructive) {
                        model.run("Removed class time.") { try model.store.apply(EditPlan(mutations: [.deletePattern(id: pattern.id)], warnings: []), label: "Remove class") }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let tz = pattern.tz
                    pattern.startTime = LocalTime(start, tz: tz); pattern.endTime = LocalTime(end, tz: tz)
                    pattern.validFrom = LocalDate(from, tz: tz); pattern.validTo = LocalDate(to, tz: tz)
                    if pattern.externalUid != nil { pattern.userModified = true }
                    model.run("Saved class time.") { _ = try model.store.savePattern(pattern); return nil }
                    dismiss()
                }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear {
            let tz = pattern.tz
            let today = LocalDate.today(tz: tz)
            start = today.at(pattern.startTime, tz: tz); end = today.at(pattern.endTime, tz: tz)
            from = pattern.validFrom.at(LocalTime(hour: 12, minute: 0), tz: tz); to = pattern.validTo.at(LocalTime(hour: 12, minute: 0), tz: tz)
        }
    }
}
