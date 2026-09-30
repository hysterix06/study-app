import SwiftUI
import StudyCore

struct InboxScreen: View {
    @Environment(AppModel.self) var model
    @State private var confirmClear = false

    var body: some View {
        let _ = model.revision
        let store = model.store
        let toFile = store.materials().filter { $0.courseId == nil }
        let ready = store.unprocessedMaterials().filter { $0.role == .lecture || $0.role == .reading }
        let otherReady = store.unprocessedMaterials().filter { $0.role == .syllabus || $0.role == .brief || $0.role == .pastExam }
        let problems = store.materials(statuses: ["failed", "needs_ocr"]).filter { $0.courseId != nil }
        let proposed = store.assignments(AssignmentFilter(onlyProposed: true))
        let blocks = store.studyBlocks(statuses: ["proposed"]).filter { $0.createdBy == "claude" }
        let cards = store.cards(status: "proposed")
        let conflicts = store.conflicts()
        let empty = toFile.isEmpty && ready.isEmpty && otherReady.isEmpty && problems.isEmpty && proposed.isEmpty && blocks.isEmpty && cards.isEmpty && conflicts.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("Inbox").font(.stTitle)
                    Spacer()
                    Button { model.chooseFilesToImport() } label: { Label("Add files", systemImage: "plus") }.buttonStyle(QuietButtonStyle())
                    Button { NSWorkspace.shared.open(store.paths.inbox) } label: { Label("Inbox folder", systemImage: "folder") }.buttonStyle(QuietButtonStyle())
                    if !empty {
                        Button { confirmClear = true } label: { Label("Clear all…", systemImage: "xmark.circle") }.buttonStyle(QuietButtonStyle())
                    }
                }
                if empty {
                    EmptyState(text: "Nothing needs a decision. Drop slides or PDFs anywhere in this window to add them.", actionTitle: "Add files") { model.chooseFilesToImport() }
                }
                if !toFile.isEmpty {
                    section("Files to file", count: toFile.count) {
                        ForEach(toFile) { m in FileToFileRow(material: m) }
                    }
                }
                if !ready.isEmpty {
                    section("Ready to process", count: ready.count, trailing: ready.count > 1 && model.jobs.mode(for: .process) == .automatic ? AnyView(Button("Process all with Claude") {
                        for m in ready { model.jobs.run(.process, material: m.id) }
                    }.buttonStyle(.borderless).font(.stSmall)) : nil) {
                        ForEach(ready) { m in ReadyRow(material: m, task: .process) }
                    }
                }
                if !otherReady.isEmpty {
                    section("Syllabi, briefs and past exams", count: otherReady.count) {
                        ForEach(otherReady) { m in ReadyRow(material: m, task: m.role == .pastExam ? .examPatterns : .extractDeadlines) }
                    }
                }
                if !proposed.isEmpty {
                    section("Proposed deadlines", count: proposed.count) {
                        ForEach(proposed) { a in ProposedAssignmentRow(a: a) }
                    }
                }
                if !blocks.isEmpty {
                    section("Study blocks proposed by Claude", count: blocks.count, trailing: AnyView(Button("Accept all") {
                        model.run("Accepted \(blocks.count) blocks.") { for b in blocks { try model.store.setBlockStatus(b.id, "planned") }; return nil }
                    }.buttonStyle(.borderless).font(.stSmall))) {
                        ForEach(blocks) { b in
                            HStack {
                                Image(systemName: "book")
                                Text(b.focus ?? "Study").font(.stBody)
                                Text("\(Formatters.dayTime(b.plannedStart, tz: model.tz)) · \(b.plannedMinutes) min").font(.stSmall).foregroundStyle(Theme.textSecondary).monospacedDigit()
                                Spacer()
                                Button("Dismiss") { model.run { try model.store.setBlockStatus(b.id, "dismissed"); return nil } }.buttonStyle(QuietButtonStyle())
                                Button("Accept") { model.run { try model.store.setBlockStatus(b.id, "planned"); return nil } }.buttonStyle(PrimaryButtonStyle())
                            }.padding(10).background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.fillSubtle))
                        }
                    }
                }
                if !cards.isEmpty {
                    section("Flashcards to approve", count: cards.count, trailing: AnyView(Button("Approve all") {
                        model.run("Approved \(cards.count) cards.") { for c in cards { try model.store.saveCard(id: c.id, front: c.front, back: c.back, status: "active") }; return nil }
                    }.buttonStyle(.borderless).font(.stSmall))) {
                        Text("Rewriting a card in your own words makes it stick better.").font(.stSmall).foregroundStyle(Theme.textSecondary)
                        ForEach(cards.prefix(12)) { c in ProposedCardRow(card: c) }
                        if cards.count > 12 { Text("\(cards.count - 12) more in each course's Cards tab.").font(.stSmall).foregroundStyle(Theme.textTertiary) }
                    }
                }
                if !conflicts.isEmpty {
                    section("Conflicts", count: conflicts.count) {
                        ForEach(conflicts) { c in
                            HStack {
                                Image(systemName: "arrow.triangle.branch")
                                Text(c.summary).font(.stBody)
                                Spacer()
                                Button("Keep mine") { model.run { try model.store.resolveConflict(c.id, acceptIncoming: false); return nil } }.buttonStyle(QuietButtonStyle())
                                Button("Use \(c.source == "moodle" ? "Moodle's" : "calendar's")") { model.run { try model.store.resolveConflict(c.id, acceptIncoming: true); return nil } }.buttonStyle(PrimaryButtonStyle())
                            }.padding(10).background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.fillSubtle))
                        }
                    }
                }
                if !problems.isEmpty {
                    section("Could not read", count: problems.count) {
                        ForEach(problems) { m in
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                VStack(alignment: .leading) {
                                    Text(m.title).font(.stBody)
                                    Text(m.statusDetail ?? m.status).font(.stSmall).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Button("Remove") { model.run("Deleted \(m.title).") { try model.store.trashMaterial(m.id) } }.buttonStyle(QuietButtonStyle())
                            }.padding(10).background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.fillSubtle))
                        }
                    }
                }
            }
            .padding(28).contentWidth()
        }
        .confirmationDialog("Clear the Inbox?", isPresented: $confirmClear) {
            Button("Clear all", role: .destructive) {
                model.run("Cleared the Inbox.") {
                    try model.store.clearInbox(deleteMaterials: (toFile + problems).map(\.id), skip: (ready + otherReady).map(\.id),
                                               dismissAssignments: proposed.map(\.id), dismissBlocks: blocks.map(\.id),
                                               deleteCards: cards.map(\.id), keepMine: conflicts.map(\.id))
                }
            }
        } message: {
            Text(clearSummary(files: toFile.count + problems.count, skipped: ready.count + otherReady.count,
                              proposals: proposed.count + blocks.count + cards.count, conflicts: conflicts.count))
        }
    }

    /// Spells out what "Clear all" does to each kind of item, naming only the kinds that are present.
    func clearSummary(files: Int, skipped: Int, proposals: Int, conflicts: Int) -> String {
        var parts: [String] = []
        if files > 0 { parts.append("\(files) unfiled or unreadable file\(files == 1 ? "" : "s") will move to Recently Deleted.") }
        if skipped > 0 { parts.append("\(skipped) filed item\(skipped == 1 ? "" : "s") will be skipped but stay in \(skipped == 1 ? "its course" : "their courses").") }
        if proposals > 0 { parts.append("\(proposals) proposed deadline\(proposals == 1 ? "" : "s"), study block\(proposals == 1 ? "" : "s") or flashcard\(proposals == 1 ? "" : "s") will be dismissed.") }
        if conflicts > 0 { parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s") will keep your version.") }
        return parts.joined(separator: " ")
    }

    func section<C: View>(_ title: String, count: Int, trailing: AnyView? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "\(title) · \(count)", trailing: trailing)
            content()
        }
    }
}

struct FileToFileRow: View {
    @Environment(AppModel.self) var model
    let m: Material
    init(material: Material) { m = material }
    @State private var courseId: Int?
    @State private var role: MaterialRole = .lecture

    var body: some View {
        let courses = model.store.courses()
        HStack(spacing: 10) {
            Image(systemName: m.status == "failed" ? "exclamationmark.triangle" : "doc").foregroundStyle(m.status == "failed" ? Theme.attention : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.stBody).lineLimit(1)
                Text(m.status == "failed" ? (m.statusDetail ?? "Could not be read") : "\(m.originalFilename ?? "") · \(m.pageCount.map { "\($0) pages" } ?? "")")
                    .font(.stSmall).foregroundStyle(m.status == "failed" ? Theme.attention : Theme.textTertiary).lineLimit(2)
            }
            Spacer()
            if m.status != "failed" {
                Picker("Role", selection: $role) { ForEach(MaterialRole.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 130)
                Picker("Course", selection: $courseId) {
                    Text("Choose course").tag(Int?.none)
                    ForEach(courses) { c in Text(c.displayName).tag(Int?.some(c.id)) }
                }.labelsHidden().frame(width: 140)
                Button("Remove") { model.run("Deleted \(m.title).") { try model.store.trashMaterial(m.id) } }.buttonStyle(QuietButtonStyle())
                Button("Confirm") {
                    guard let courseId else { return }
                    model.run("Filed \(m.title).") { try model.store.confirmMaterial(m.id, courseId: courseId, role: role); return nil }
                    if model.store.boolSetting("auto_process") && role == .lecture { model.jobs.run(.process, material: m.id) }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(courseId == nil).keyboardShortcut(.defaultAction)
            } else {
                Button("Remove") { model.run("Deleted \(m.title).") { try model.store.trashMaterial(m.id) } }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.fillSubtle))
        .onAppear { courseId = m.suggestedCourseId; role = m.role }
    }
}

struct ReadyRow: View {
    @Environment(AppModel.self) var model
    let m: Material
    let task: ClaudeTask
    init(material: Material, task: ClaudeTask) { m = material; self.task = task }
    var body: some View {
        let course = m.courseId.flatMap { model.store.course($0) }
        HStack(spacing: 10) {
            CourseDot(color: course?.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.stBody).lineLimit(1)
                Text("\(course?.displayName ?? "") · \(m.role.label)").font(.stSmall).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button("Skip") { model.run("Skipped \(m.title). It stays in its course.") { try model.store.skipMaterialUndoable(m.id) } }
                .buttonStyle(QuietButtonStyle()).help("Remove from the Inbox without processing. The file stays in its course.")
            ClaudeButton(task: task) { model.jobs.run(task, material: m.id) }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(10).background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.fillSubtle))
    }
}

struct ProposedAssignmentRow: View {
    @Environment(AppModel.self) var model
    var a: Assignment
    @State private var courseId: Int?
    var body: some View {
        let courses = model.store.courses()
        HStack(spacing: 10) {
            Image(systemName: a.kind == .exam ? "exclamationmark.square" : "flag")
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.stBody)
                Text([Formatters.due(a.dueAt, tz: model.tz), a.weightPct.map { Formatters.percent($0) }, a.source == "claude" ? "from Claude" : "from \(a.source.uppercased())", a.sourceLocator]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.stSmall).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Picker("Course", selection: $courseId) {
                Text("Choose course").tag(Int?.none)
                ForEach(courses) { c in Text(c.displayName).tag(Int?.some(c.id)) }
            }.labelsHidden().frame(width: 140)
            Button("Dismiss") { model.run("Dismissed.") { try model.store.dismissProposedUndoable(a.id) } }.buttonStyle(QuietButtonStyle())
            Button("Confirm") { model.run("Added \(a.title).") { try model.store.confirmProposed(a.id, courseId: courseId); return nil } }
                .buttonStyle(PrimaryButtonStyle()).disabled(courseId == nil)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.fillSubtle))
        .onAppear { courseId = a.courseId }
    }
}

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
