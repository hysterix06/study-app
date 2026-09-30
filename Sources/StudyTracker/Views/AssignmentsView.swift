import SwiftUI
import StudyCore
import UniformTypeIdentifiers

struct AssignmentsScreen: View {
    @Environment(AppModel.self) var model
    @AppStorage("assignments.board") var board = false
    @AppStorage("assignments.course") var courseFilter = 0

    var body: some View {
        let _ = model.revision
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Assignments").font(.stTitle)
                        Spacer()
                        Picker("Course", selection: $courseFilter) {
                            Text("All courses").tag(0)
                            ForEach(model.store.courses()) { c in Text(c.displayName).tag(c.id) }
                        }.frame(width: 180).labelsHidden()
                        Picker("", selection: $board) { Image(systemName: "list.bullet").tag(false); Image(systemName: "rectangle.split.3x1").tag(true) }
                            .pickerStyle(.segmented).frame(width: 90).labelsHidden()
                            .accessibilityLabel("List or board")
                    }
                    QuickAddBar()
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
                Divider()
                let items = model.store.assignments(AssignmentFilter(courseId: courseFilter == 0 ? nil : courseFilter))
                if items.isEmpty {
                    EmptyState(text: "No assignments yet. Type one above, like \"Pricing report HM210 fri 5pm 30% 6h\".")
                    Spacer()
                } else if board {
                    AssignmentBoard(items: items)
                } else {
                    AssignmentList(items: items)
                }
            }
            if let id = model.selectedAssignmentId, let a = model.store.assignment(id) {
                Divider()
                AssignmentDetail(assignment: a).frame(width: 360).id(id)
            }
        }
    }
}

// MARK: Quick add (§7.5)

struct QuickAddBar: View {
    @Environment(AppModel.self) var model
    @State private var text = ""
    @State private var pickedCourse: Int?
    @FocusState private var focused: Bool

    var body: some View {
        let courses = model.store.courses()
        let parsed = QuickAddParser(courses: courses, tz: model.tz, defaultDueTime: model.store.defaultDueTime, dayFirst: model.store.dayFirstDates).parse(text)
        let courseId = pickedCourse ?? parsed.courseId
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "plus").foregroundStyle(Theme.textTertiary)
                TextField("Add an assignment: title, course, date, weight, hours", text: $text)
                    .textFieldStyle(.plain).font(.stBodyStrong)
                    .focused($focused)
                    .onSubmit { save(parsed, courseId: courseId) }
                    .accessibilityLabel("Quick add assignment")
                if !text.isEmpty {
                    Button("Add") { save(parsed, courseId: courseId) }.buttonStyle(PrimaryButtonStyle()).disabled(courseId == nil)
                }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: Theme.corner(8)).fill(Theme.fillSubtle))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner(8)).strokeBorder(focused ? Theme.textPrimary.opacity(0.25) : Theme.hairline))
            if !text.isEmpty {
                HStack(spacing: 6) {
                    // The course chip is a picker; it is highlighted when the course is missing or ambiguous.
                    Menu {
                        ForEach(parsed.courseCandidates.isEmpty ? courses.map(\.id) : parsed.courseCandidates, id: \.self) { id in
                            if let c = courses.first(where: { $0.id == id }) { Button(c.names.prefix(2).joined(separator: " · ")) { pickedCourse = id } }
                        }
                        if !parsed.courseCandidates.isEmpty { Divider(); ForEach(courses) { c in Button(c.displayName) { pickedCourse = c.id } } }
                    } label: {
                        HStack(spacing: 4) {
                            if let id = courseId, let c = courses.first(where: { $0.id == id }) { CourseDot(color: c.color); Text(c.displayName) }
                            else { Image(systemName: "questionmark.circle"); Text(parsed.courseCandidates.count > 1 ? "Which course?" : "Pick a course") }
                        }.font(.stSmall)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Theme.corner(4)).fill(courseId == nil ? Theme.attention.opacity(0.12) : Theme.fillSubtle))
                    ForEach(parsed.pieces.filter { $0.kind != .course }, id: \.self) { p in
                        Chip(text: p.text, systemImage: icon(p.kind))
                    }
                    Spacer()
                    Text(parsed.title).font(.stSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
        }
        .onChange(of: model.focusQuickAdd) { focused = true }
        .onChange(of: text) { if text.isEmpty { pickedCourse = nil } }
        .onAppear { if model.focusQuickAdd > 0 { focused = true } }
    }

    func icon(_ k: QuickAddResult.Piece.Kind) -> String {
        switch k { case .due: return "calendar"; case .weight: return "percent"; case .hours: return "clock"; case .kind: return "tag"; case .course: return "book" }
    }

    func save(_ p: QuickAddResult, courseId: Int?) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let courseId else { model.show("Pick a course first. Quick add never guesses one silently.", error: true); return }
        let a = Assignment(courseId: courseId, title: p.title, kind: p.kind, dueAt: p.dueAt, weightPct: p.weightPct, estHours: p.estHours)
        do {
            let id = try model.store.saveAssignment(a)
            model.refresh()
            model.show("Added \(p.title).", undo: model.store.assignmentSnapshot([], label: "Add", inserted: [id]))
            text = ""; pickedCourse = nil
        } catch { model.fail(error) }
    }
}

// MARK: List

struct AssignmentList: View {
    @Environment(AppModel.self) var model
    var items: [Assignment]
    @State private var expanded: Set<String> = []

    var body: some View {
        let now = Date()
        let courses = model.store.courseMap()
        let tz = model.tz
        let weekEnd = LocalDate.today(tz: tz).startOfWeek(weekStartsOn: model.store.weekStartsOn).adding(days: 7).at(LocalTime(hour: 0, minute: 0), tz: tz)
        let groups: [(String, [Assignment], Bool)] = [
            ("Overdue", items.filter { $0.isOverdue(now: now) }, false),
            ("Due this week", items.filter { a in a.isOpen && a.dueAt.map { $0 >= now && $0 < max(weekEnd, now.adding(days: 3)) } == true }, false),
            ("Later", items.filter { a in a.isOpen && a.dueAt.map { $0 >= max(weekEnd, now.adding(days: 3)) } == true }, false),
            ("No date", items.filter { $0.isOpen && $0.dueAt == nil }, false),
            ("Done", items.filter { !$0.isOpen }.sorted { ($0.dueAt ?? .distantPast) > ($1.dueAt ?? .distantPast) }, true),
        ]
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(groups, id: \.0) { title, list, collapsedByDefault in
                    if !list.isEmpty {
                        let isOpen = collapsedByDefault ? expanded.contains(title) : !expanded.contains(title)
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                                    Text(title.uppercased()).font(.stSmallStrong).kerning(0.6)
                                    Text("\(list.count)").font(.stSmall).monospacedDigit()
                                    if title == "Overdue" { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)) }
                                }.foregroundStyle(title == "Overdue" ? Theme.attention : Theme.textTertiary)
                            }.buttonStyle(.plain)
                            if isOpen {
                                let limit = expanded.contains(title + ".more") ? list.count : 7
                                ForEach(list.prefix(limit)) { a in AssignmentRow(a: a, courses: courses) }
                                if list.count > 7 && limit == 7 {
                                    Button("Show \(list.count - 7) more") { expanded.insert(title + ".more") }.buttonStyle(.borderless).font(.stSmall)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24).contentWidth()
        }
    }
}

struct StatusControl: View {
    @Environment(AppModel.self) var model
    var a: Assignment
    var body: some View {
        Menu {
            ForEach(AssignmentStatus.allCases) { s in
                Button { setStatus(s) } label: { Label(s.label, systemImage: icon(s)) }
            }
        } label: {
            Image(systemName: icon(a.status)).font(.system(size: 15))
                .foregroundStyle(a.isOpen ? Theme.textSecondary : Theme.textPrimary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Status: \(a.status.label)")
    }
    func icon(_ s: AssignmentStatus) -> String {
        switch s { case .notStarted: return "circle"; case .inProgress: return "circle.lefthalf.filled"; case .submitted: return "checkmark.circle"; case .graded: return "checkmark.seal" }
    }
    func setStatus(_ s: AssignmentStatus) {
        let snap = model.store.assignmentSnapshot([a.id], label: "Status")
        model.run("\(a.title): \(s.label).") { try model.store.setStatus(a.id, s); return snap }
    }
}

struct AssignmentRow: View {
    @Environment(AppModel.self) var model
    var a: Assignment
    var courses: [Int: Course]
    var body: some View {
        let now = Date()
        let overdue = a.isOverdue(now: now)
        let soon = a.isOpen && (a.dueAt.map { $0 > now && $0.timeIntervalSince(now) < 48 * 3600 } ?? false)
        let course = a.courseId.flatMap { courses[$0] }
        HStack(spacing: 10) {
            StatusControl(a: a)
            CourseDot(color: course?.color)
            if a.kind == .exam { Image(systemName: "exclamationmark.square").accessibilityLabel("Exam") }
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.stBody).strikethrough(!a.isOpen && a.status == .submitted ? false : false)
                    .foregroundStyle(a.isOpen ? Theme.textPrimary : Theme.textSecondary)
                HStack(spacing: 6) {
                    Text(course?.displayName ?? "No course").font(.stSmall).foregroundStyle(Theme.textTertiary)
                    if a.groupMembers != nil { Image(systemName: "person.2").font(.system(size: 10)).foregroundStyle(Theme.textTertiary).accessibilityLabel("Group work") }
                    if a.source == "moodle" { Text("Moodle").font(.stSmall).foregroundStyle(Theme.textTertiary) }
                }
            }
            Spacer()
            if let pct = a.scorePct, a.status == .graded { Chip(text: Formatters.percent((pct * 10).rounded() / 10), systemImage: "checkmark") }
            if let w = a.weightPct { Chip(text: Formatters.percent(w)) }
            if let h = a.estHours { Chip(text: Formatters.hours(h), systemImage: "clock") }
            HStack(spacing: 3) {
                if overdue { Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Overdue") }
                Text(Formatters.due(a.dueAt, tz: model.tz, now: now))
            }
            .font(.stSmall).monospacedDigit().lineLimit(1).fixedSize()
            .foregroundStyle(overdue || soon ? Theme.attention : Theme.textSecondary)
            .frame(minWidth: 170, alignment: .trailing)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(model.selectedAssignmentId == a.id ? Theme.textPrimary.opacity(0.07) : Theme.fillSubtle))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedAssignmentId = a.id }
        .onDrag { NSItemProvider(object: "\(a.id)" as NSString) }
    }
}

// MARK: Board

struct AssignmentBoard: View {
    @Environment(AppModel.self) var model
    var items: [Assignment]
    var body: some View {
        let courses = model.store.courseMap()
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(AssignmentStatus.allCases) { status in
                    let col = items.filter { $0.status == status }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(status.label.uppercased()).font(.stSmallStrong).kerning(0.6).foregroundStyle(Theme.textTertiary); Text("\(col.count)").font(.stSmall).foregroundStyle(Theme.textTertiary) }
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(col) { a in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) { CourseDot(color: a.courseId.flatMap { courses[$0]?.color }); Text(a.title).font(.stBody).lineLimit(2) }
                                        HStack {
                                            Text(Formatters.due(a.dueAt, tz: model.tz)).font(.stSmall).monospacedDigit()
                                                .foregroundStyle(a.isOverdue(now: Date()) ? Theme.attention : Theme.textSecondary)
                                            Spacer()
                                            if let w = a.weightPct { Chip(text: Formatters.percent(w)) }
                                        }
                                    }
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: Theme.corner(8)).fill(.background))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.corner(8)).strokeBorder(Theme.hairline))
                                    .onTapGesture { model.selectedAssignmentId = a.id }
                                    .onDrag { NSItemProvider(object: "\(a.id)" as NSString) }
                                }
                            }
                        }
                    }
                    .padding(12).frame(width: 260).frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: Theme.corner(10)).fill(Theme.fillSubtle))
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        providers.first?.loadObject(ofClass: NSString.self) { s, _ in
                            guard let s = s as? String, let id = Int(s) else { return }
                            DispatchQueue.main.async {
                                let snap = model.store.assignmentSnapshot([id], label: "Status")
                                model.run("Moved to \(status.label).") { try model.store.setStatus(id, status); return snap }
                            }
                        }
                        return true
                    }
                }
            }.padding(20)
        }
    }
}

// MARK: Detail panel

struct AssignmentDetail: View {
    @Environment(AppModel.self) var model
    @State var assignment: Assignment
    @State private var hasDue = false
    @State private var due = Date()
    @State private var dirty = false

    var body: some View {
        let courses = model.store.courses()
        let materials = assignment.courseId.map { model.store.materials(courseId: $0) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Details").font(.stHeading)
                    Spacer()
                    Button { model.selectedAssignmentId = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close")
                }
                TextField("Title", text: $assignment.title, axis: .vertical).font(.stBodyStrong).textFieldStyle(.plain)
                Form {
                    Picker("Course", selection: $assignment.courseId) {
                        ForEach(courses) { c in Text(c.displayName).tag(Int?.some(c.id)) }
                    }
                    Picker("Kind", selection: $assignment.kind) { ForEach(AssignmentKind.allCases) { Text($0.label).tag($0) } }
                    Picker("Status", selection: $assignment.status) { ForEach(AssignmentStatus.allCases) { Text($0.label).tag($0) } }
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue { DatePicker("Due", selection: $due).environment(\.timeZone, model.tz) }
                    NumberField(label: "Weight %", value: $assignment.weightPct)
                    NumberField(label: "Estimate (h)", value: $assignment.estHours)
                    NumberField(label: "Score", value: $assignment.score)
                    NumberField(label: "Out of", value: $assignment.maxScore)
                    NumberField(label: "Minimum to pass %", value: $assignment.minPassPct)
                    TextField("Group members", text: Binding(get: { assignment.groupMembers ?? "" }, set: { assignment.groupMembers = $0.isEmpty ? nil : $0 }))
                    Picker("Rubric / brief", selection: $assignment.rubricMaterialId) {
                        Text("None").tag(Int?.none)
                        ForEach(materials) { m in Text(m.title).tag(Int?.some(m.id)) }
                    }
                    if let rid = assignment.rubricMaterialId {
                        Button("Open rubric or brief") { model.openMaterial(rid) }.buttonStyle(.borderless)
                    }
                    if let sid = assignment.sourceMaterialId, let src = model.store.material(sid) {
                        Button("From \(src.title)") { model.openMaterial(sid) }.buttonStyle(.borderless)
                    }
                }
                .formStyle(.grouped).scrollDisabled(true)
                .onChange(of: assignment) { dirty = true }
                .onChange(of: hasDue) { dirty = true }
                .onChange(of: due) { dirty = true }

                if let w = assignment.weightPct {
                    let earned = assignment.status == .graded ? assignment.scorePct.map { $0 / 100 * w } : nil
                    Text(earned.map { String(format: "Earned %.1f of %g points of your final grade.", $0, w) } ?? "Worth \(String(format: "%g", w)) points of your final grade.")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
                TextField("Notes", text: Binding(get: { assignment.description ?? "" }, set: { assignment.description = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    .lineLimit(3...10).textFieldStyle(.roundedBorder)
                if let loc = assignment.sourceLocator, let mid = assignment.sourceMaterialId, let m = model.store.material(mid) {
                    Label("From \(m.title), \(loc)", systemImage: "doc.text").font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
                if let u = assignment.url, let url = URL(string: u) {
                    Link(destination: url) { Label("Open in Moodle", systemImage: "arrow.up.right.square") }.font(.stSmall)
                }
                let blocks = model.store.studyBlocks(statuses: ["proposed", "planned", "done"]).filter { $0.assignmentId == assignment.id }
                if !blocks.isEmpty {
                    SectionHeader(title: "Study blocks")
                    ForEach(blocks) { b in
                        HStack { Text(Formatters.dayTime(b.plannedStart, tz: model.tz)).monospacedDigit(); Spacer(); Text("\(b.plannedMinutes) min · \(b.status)") }
                            .font(.stSmall).foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack {
                    Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(!dirty).keyboardShortcut("s")
                    Menu("More") {
                        Button("Plan study blocks") { model.planStudy(focusAssignment: assignment.id) }
                        Button(ClaudeTask.checkDraft.label) { model.jobs.run(.checkDraft, assignment: assignment.id) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            let title = assignment.title
                            do {
                                let snap = try model.store.trashAssignment(assignment.id)
                                model.selectedAssignmentId = nil
                                model.refresh()
                                model.show("Deleted \(title).", undo: snap)
                            } catch { model.fail(error) }
                        }
                    }.fixedSize()
                }
            }
            .padding(20)
        }
        .onAppear { hasDue = assignment.dueAt != nil; due = assignment.dueAt ?? Date().adding(days: 7); dirty = false }
    }

    func save() {
        var a = assignment
        a.dueAt = hasDue ? due : nil
        if a.status == .submitted && a.submittedAt == nil { a.submittedAt = Date() }
        if a.status.isOpen { a.submittedAt = nil }
        let snap = model.store.assignmentSnapshot([a.id], label: "Edit")
        model.run("Saved \(a.title).") { try model.store.saveAssignment(a); return snap }
        dirty = false
    }
}

struct NumberField: View {
    var label: String
    @Binding var value: Double?
    var body: some View {
        TextField(label, text: Binding(
            get: { value.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" },
            set: { value = Double($0.replacingOccurrences(of: ",", with: ".")) }))
            .multilineTextAlignment(.trailing).monospacedDigit()
    }
}
