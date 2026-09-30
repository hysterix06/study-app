import SwiftUI
import StudyCore

struct CoursesScreen: View {
    @Environment(AppModel.self) var model
    @State private var editing: Course?

    var body: some View {
        let _ = model.revision
        let courses = model.store.courses(includeArchived: true)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Courses").font(.stHeading)
                    Spacer()
                    Button { newCourse() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).accessibilityLabel("Add course")
                }.padding(16)
                List(selection: Binding(get: { model.selectedCourseId }, set: { model.selectedCourseId = $0 })) {
                    ForEach(courses) { c in
                        HStack(spacing: 8) {
                            CourseDot(color: c.color)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.displayName).font(.stBodyStrong)
                                if let sub = c.secondaryName { Text(sub).font(.stSmall).foregroundStyle(Theme.secondaryText).lineLimit(1) }
                            }
                        }
                        .opacity(c.archived ? 0.5 : 1)
                        .tag(c.id)
                    }
                }
            }
            .frame(width: 240)
            Divider()
            if let id = model.selectedCourseId ?? courses.first?.id, let c = courses.first(where: { $0.id == id }) {
                CourseDetail(course: c, onEdit: { editing = c }).id(c.id)
            } else {
                EmptyState(text: "Add your courses, or import a timetable and they appear here.", actionTitle: "Add course") { newCourse() }
            }
        }
        .sheet(item: $editing) { c in CourseEditor(course: c) }
    }

    func newCourse() {
        guard let term = model.store.currentTerm() else {
            model.show("Add a term first in Settings › Terms and breaks.", error: true); model.go(.settings(.terms)); return
        }
        editing = Course(termId: term.id, code: "", name: "", color: model.store.nextCourseColor())
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
                if let code = course.code { Text(code).font(.stHeading).foregroundStyle(Theme.tertiaryText) }
                Spacer()
                Button("Edit") { onEdit() }.buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 24).padding(.top, 20)
            if let i = course.instructor { Text(i).font(.stBody).foregroundStyle(Theme.secondaryText).padding(.horizontal, 24) }
            Picker("", selection: $model.courseTab) { ForEach(CourseTab.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 620)
            Divider()
            ScrollView {
                Group {
                    switch model.courseTab {
                    case .overview: CourseOverview(course: course)
                    case .assignments: CourseAssignments(course: course)
                    case .materials: CourseMaterials(course: course)
                    case .concepts: CourseConcepts(course: course)
                    case .notes: CourseNotes(course: course)
                    case .cards: CourseCards(course: course)
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
                if open.isEmpty { Text("Nothing open for this course.").font(.stBody).foregroundStyle(Theme.secondaryText) }
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

// MARK: Overview

struct CourseOverview: View {
    @Environment(AppModel.self) var model
    var course: Course
    @State private var addingPattern = false
    @State private var editPattern: ClassPattern?

    var body: some View {
        let _ = model.revision
        let store = model.store
        VStack(alignment: .leading, spacing: 22) {
            GradeCard(course: course)
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Weekly schedule", trailing: AnyView(Button("Add class time") { addingPattern = true }.buttonStyle(.borderless).font(.stSmall)))
                let patterns = store.patterns(courseId: course.id)
                if patterns.isEmpty { Text("No weekly classes yet.").font(.stBody).foregroundStyle(Theme.secondaryText) }
                ForEach(patterns) { p in
                    HStack {
                        Text(weekdayName(p.weekday)).frame(width: 90, alignment: .leading)
                        Text("\(p.startTime.string)–\(p.endTime.string)").monospacedDigit()
                        if let l = p.location { Text(l).foregroundStyle(Theme.secondaryText) }
                        Spacer()
                        Text("\(p.validFrom.string) → \(p.validTo.string)").font(.stSmall).foregroundStyle(Theme.tertiaryText).monospacedDigit()
                        Button("Edit") { editPattern = p }.buttonStyle(.borderless).font(.stSmall)
                    }.font(.stBody).padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Upcoming")
                let upcoming = store.assignments(AssignmentFilter(courseId: course.id)).filter { $0.isOpen }.prefix(7)
                if upcoming.isEmpty { Text("Nothing open for this course.").font(.stBody).foregroundStyle(Theme.secondaryText) }
                ForEach(Array(upcoming)) { a in AssignmentLine(a: a, courses: store.courseMap()).onTapGesture { model.openAssignment(a.id) } }
            }
            let weak = store.weakConcepts(courseId: course.id)
            if !weak.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Concepts flagged weak recently")
                    ForEach(weak.prefix(6), id: \.concept.id) { w in
                        HStack { Text(w.concept.name).font(.stBody); Spacer(); Text("\(w.count)×").font(.stSmall).foregroundStyle(Theme.secondaryText) }
                    }
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
                Text(String(describing: error)).font(.stSmall).foregroundStyle(Theme.accent)
            case .success(let s):
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(s.currentOnScale.map { course.gradeScale.format($0) } ?? "—").font(.stTitle).monospacedDigit()
                    if let t = course.targetGrade { Text("Target \(course.gradeScale.format(t))").font(.stBody).foregroundStyle(Theme.secondaryText) }
                    Spacer()
                }
                Text(s.headline).font(.stBodyStrong)
                    .foregroundStyle(s.state == .unreachable || s.state == .componentFailed ? Theme.accent : .primary)
                if s.totalWeight > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.subtleFill)
                            RoundedRectangle(cornerRadius: 3).fill(Theme.courseColor(course.color))
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
                        .font(.stSmall).foregroundStyle(Theme.secondaryText).monospacedDigit()
                    }
                }
                if let w = s.weightWarning { Label(w, systemImage: "info.circle").font(.stSmall).foregroundStyle(Theme.secondaryText) }
                ForEach(s.pendingMinimums, id: \.id) { p in
                    Label("\(p.title) needs at least \(Formatters.percent(p.minPct)) to pass.", systemImage: "exclamationmark.circle").font(.stSmall)
                }
                if course.targetGrade == nil {
                    Text("Set a target grade with Edit to see what you need on the remaining work.").font(.stSmall).foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }
}

// MARK: Materials

struct CourseMaterials: View {
    @Environment(AppModel.self) var model
    var course: Course
    var body: some View {
        let _ = model.revision
        let list = model.store.materials(courseId: course.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Materials")
                Button("Add files…") { model.chooseFilesToImport() }.buttonStyle(.borderless).font(.stSmall)
            }
            if list.isEmpty { EmptyState(text: "Drop slides, PDFs or Word files here to add them to \(course.displayName).") }
            ForEach(list) { m in MaterialRow(material: m) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { model.importFiles($0, courseId: course.id) }
            return true
        }
    }
}

struct MaterialRow: View {
    @Environment(AppModel.self) var model
    let m: Material
    init(material: Material) { m = material }
    var body: some View {
        let concepts = model.store.concepts(materialId: m.id).count
        let chunks = model.store.chunks(materialId: m.id)
        let pictures = chunks.filter { !$0.images.isEmpty }.count
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.stBody).lineLimit(1)
                HStack(spacing: 6) {
                    Text(m.role.label)
                    Text("·"); Text("\(chunks.count) \(m.kind == "slides" ? "slides" : "parts")")
                    if pictures > 0 { Text("·"); Text("\(pictures) with pictures") }
                    if m.processedAt != nil { Text("·"); Text("\(concepts) concepts") }
                    if m.status == "failed" || m.status == "needs_ocr" { Text("·"); Text(m.statusDetail ?? m.status).foregroundStyle(Theme.accent) }
                }.font(.stSmall).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            }
            Spacer()
            if m.processedAt != nil { Chip(text: "Processed", systemImage: "checkmark") }
            Menu {
                Button("Open file") { if let p = m.storedPath { NSWorkspace.shared.open(model.store.paths.absolute(p)) } }
                Button("Study this") { model.openMaterial(m.id) }
                Divider()
                Button(model.claude.findCLI() != nil ? "Process with Claude now" : "Copy \"process lecture\" prompt") { model.process(materialId: m.id) }
                Button("Copy \"process lecture\" prompt") { model.copyPrompt("process_lecture", ["material_id": "\(m.id)"]) }
                if m.role == .syllabus || m.role == .brief { Button("Copy \"extract deadlines\" prompt") { model.copyPrompt("extract_deadlines", ["material_id": "\(m.id)"]) } }
                if m.role == .pastExam { Button("Copy \"past exam patterns\" prompt") { model.copyPrompt("exam_patterns", ["material_id": "\(m.id)"]) } }
                Button("Copy \"practice problems\" prompt") { model.copyPrompt("practice_problems", ["material_id": "\(m.id)"]) }
                Divider()
                Menu("Role") { ForEach(MaterialRole.allCases) { r in Button(r.label) { model.run { try model.store.updateMaterial(m.id, role: r); return nil } } } }
                Button("Move to Trash", role: .destructive) { model.run("Moved \(m.title) to the Trash.") { try model.store.deleteMaterial(m.id); return nil } }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtleFill))
    }
    var icon: String {
        switch m.kind { case "slides": return "rectangle.on.rectangle"; case "pdf": return "doc.richtext"; case "doc": return "doc.text"; case "image": return "photo"; default: return "text.alignleft" }
    }
}

// MARK: Concepts

struct CourseConcepts: View {
    @Environment(AppModel.self) var model
    var course: Course
    @State private var name = ""
    @State private var definition = ""
    @State private var query = ""

    var body: some View {
        let _ = model.revision
        let all = model.store.concepts(courseId: course.id)
        let concepts = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.definition.localizedCaseInsensitiveContains(query) }
        let names = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
        let links = model.store.conceptLinks(courseId: course.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "\(all.count) concepts across lectures")
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            if all.isEmpty { EmptyState(text: "Concepts appear here when Claude processes a lecture, or add your own below.") }
            ForEach([1, 2, 3], id: \.self) { imp in
                let group = concepts.filter { $0.importance == imp }
                if !group.isEmpty {
                    Text(["Core", "Supporting", "Detail"][imp - 1]).font(.stSmallStrong).foregroundStyle(Theme.tertiaryText)
                    ForEach(group) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.name).font(.stBodyStrong)
                                if c.createdBy == "user" { Chip(text: "yours") }
                                Spacer()
                                Button { model.copyPrompt("feynman_check", ["concept_id": "\(c.id)"]) } label: { Label("Explain it", systemImage: "person.wave.2") }
                                    .buttonStyle(.borderless).font(.stSmall).help("Copy a Feynman-check prompt")
                            }
                            Text(c.definition).font(.stBody).foregroundStyle(Theme.secondaryText)
                            let src = model.store.conceptSources(c.id)
                            if !src.isEmpty {
                                let grouped = Dictionary(grouping: src, by: \.materialTitle).sorted { $0.key < $1.key }
                                Text(grouped.map { "\($0.key): " + $0.value.map(\.locator).joined(separator: ", ") }.joined(separator: " · "))
                                    .font(.stSmall).foregroundStyle(Theme.tertiaryText)
                            }
                            let out = links.filter { $0.from == c.id }
                            if !out.isEmpty {
                                Text(out.compactMap { l in names[l.to].map { "\(l.relation.replacingOccurrences(of: "_", with: " ")) → \($0)" } }.joined(separator: "   "))
                                    .font(.stSmall).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtleFill))
                    }
                }
            }
            Divider().padding(.vertical, 6)
            SectionHeader(title: "Add your own concept")
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Definition in your words", text: $definition, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            Button("Add concept") {
                model.run("Added \(name).") { try model.store.saveUserConcept(courseId: course.id, name: name, definition: definition, importance: 2); return nil }
                name = ""; definition = ""
            }.disabled(name.isEmpty || definition.isEmpty)
        }
    }
}

// MARK: Notes and sheets

struct CourseNotes: View {
    @Environment(AppModel.self) var model
    var course: Course
    @State private var open: Note?
    @State private var composing = false

    var body: some View {
        let _ = model.revision
        let notes = model.store.notes(courseId: course.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Sheets and notes")
                Button("New note") { composing = true }.buttonStyle(.borderless).font(.stSmall)
            }
            if notes.isEmpty { EmptyState(text: "Cornell sheets, gap reports and rubric checks from Claude appear here.") }
            ForEach(notes) { n in
                HStack(spacing: 10) {
                    Image(systemName: n.kind == "cornell_sheet" ? "square.split.2x1" : "doc.plaintext").foregroundStyle(Theme.secondaryText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.title).font(.stBody)
                        Text("\(n.kind.replacingOccurrences(of: "_", with: " ").capitalizedFirst) · \(n.createdBy == "claude" ? "Claude" : "You") · \(Formatters.day(n.updatedAt, tz: model.tz))")
                            .font(.stSmall).foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer()
                    if n.kind == "cornell_sheet" {
                        Button("Print") { model.exportSheet(n, print: true) }.buttonStyle(QuietButtonStyle())
                        Button("PDF") { model.exportSheet(n, print: false) }.buttonStyle(QuietButtonStyle())
                    }
                    Button("Open") { open = n }.buttonStyle(QuietButtonStyle())
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtleFill))
            }
        }
        .sheet(item: $open) { n in NoteViewer(note: n) }
        .sheet(isPresented: $composing) { NoteComposer(courseId: course.id) }
    }
}

struct NoteViewer: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(note.title).font(.stHeading)
                Spacer()
                if note.createdBy == "user" { Button("Delete", role: .destructive) { model.run("Deleted note.") { try model.store.deleteNote(note.id); return nil }; dismiss() } }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(LocalizedStringKey(note.contentMd)).font(.stBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 640, height: 560)
    }
}

struct NoteComposer: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var courseId: Int
    @State private var title = ""
    @State private var content = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $content).font(.stBody).frame(minHeight: 260).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") {
                model.run("Saved note.") { _ = try model.store.saveUserNote(courseId: courseId, materialId: nil, title: title, content: content); return nil }
                dismiss()
            }.buttonStyle(PrimaryButtonStyle()).disabled(title.isEmpty) }
        }.padding(20).frame(width: 560)
    }
}

// MARK: Cards

struct CourseCards: View {
    @Environment(AppModel.self) var model
    var course: Course
    @State private var front = ""
    @State private var back = ""

    var body: some View {
        let _ = model.revision
        let proposed = model.store.cards(courseId: course.id, status: "proposed")
        let active = model.store.cards(courseId: course.id, status: "active")
        let suspended = model.store.cards(courseId: course.id, status: "suspended")
        let questions = model.store.questions(courseId: course.id)
        let carded = Set(active.compactMap(\.questionId))
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "\(active.count) cards · \(active.filter { $0.due <= Date() }.count) due")
                Button("Review this course") { model.startReview(courseId: course.id) }.buttonStyle(PrimaryButtonStyle())
            }
            if !proposed.isEmpty {
                SectionHeader(title: "Proposed by Claude — approve or rewrite in your own words")
                ForEach(proposed) { c in ProposedCardRow(card: c) }
            }
            SectionHeader(title: "Write a card")
            TextField("Front (a question)", text: $front).textFieldStyle(.roundedBorder)
            TextField("Back (short answer)", text: $back).textFieldStyle(.roundedBorder)
            Button("Add card") {
                model.run("Card added.") { _ = try model.store.addUserCard(courseId: course.id, materialId: nil, front: front, back: back); return nil }
                front = ""; back = ""
            }.disabled(front.isEmpty || back.isEmpty)
            let uncarded = questions.filter { !carded.contains($0.id) }
            if !uncarded.isEmpty {
                SectionHeader(title: "Practice questions — add to deck")
                ForEach(uncarded.prefix(30)) { q in
                    HStack {
                        Text(q.prompt).font(.stBody).lineLimit(2)
                        Spacer()
                        Chip(text: q.kind)
                        Button("Add to deck") { model.run("Added to deck.") { _ = try model.store.cardFromQuestion(q); return nil } }.buttonStyle(.borderless).font(.stSmall)
                    }
                }
            }
            if !active.isEmpty {
                SectionHeader(title: "Deck")
                ForEach(active.prefix(100)) { c in
                    HStack {
                        Text(c.front).font(.stBody).lineLimit(1)
                        Spacer()
                        Text(CardState(rawValue: c.state)?.label ?? "").font(.stSmall).foregroundStyle(Theme.tertiaryText)
                        Text(c.due <= Date() ? "due" : RelativeTime.describe(c.due)).font(.stSmall).monospacedDigit().foregroundStyle(Theme.secondaryText)
                        Button("Suspend") { model.run { try model.store.saveCard(id: c.id, front: c.front, back: c.back, status: "suspended"); return nil } }
                            .buttonStyle(.borderless).font(.stSmall)
                    }
                }
            }
            if !suspended.isEmpty {
                SectionHeader(title: "Suspended")
                ForEach(suspended) { c in
                    HStack { Text(c.front).font(.stBody).lineLimit(1).foregroundStyle(Theme.secondaryText); Spacer()
                        Button("Restore") { model.run { try model.store.saveCard(id: c.id, front: c.front, back: c.back, status: "active"); return nil } }.buttonStyle(.borderless).font(.stSmall) }
                }
            }
        }
    }
}

struct ProposedCardRow: View {
    @Environment(AppModel.self) var model
    var card: Card
    @State private var front = ""
    @State private var back = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Front", text: $front, axis: .vertical).textFieldStyle(.roundedBorder)
            TextField("Back", text: $back, axis: .vertical).textFieldStyle(.roundedBorder)
            HStack {
                if let l = card.sourceLocators { Text(l).font(.stSmall).foregroundStyle(Theme.tertiaryText) }
                Spacer()
                Button("Discard") { model.run { try model.store.deleteCard(card.id); return nil } }.buttonStyle(QuietButtonStyle())
                Button(front != card.front || back != card.back ? "Save my version" : "Approve") {
                    model.run { try model.store.saveCard(id: card.id, front: front, back: back, status: "active"); return nil }
                }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtleFill))
        .onAppear { front = card.front; back = card.back }
    }
}

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
                        model.run("Deleted \(name).") { try model.store.deleteCourse(course.id); return nil }
                        model.selectedCourseId = nil
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
                        model.selectedCourseId = id
                        model.refresh()
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
