import SwiftUI
import AppKit
import StudyCore

/// The one home for any file (`material/{id}`): the study flow for lectures and readings, extracted deadlines for
/// syllabi and briefs, exam patterns for past exams, and the reason plus a fix when a file couldn't be read.
struct MaterialPage: View {
    @Environment(AppModel.self) var model
    var materialId: Int

    var body: some View {
        let _ = model.revision
        if let m = model.store.material(materialId) {
            VStack(alignment: .leading, spacing: 22) {
                MaterialHeader(m: m)
                if m.status == "failed" || m.status == "needs_ocr" { MaterialProblem(m: m) }
                switch m.role {
                case .syllabus, .brief, .rubric: MaterialDeadlines(m: m)
                case .pastExam: MaterialExamPatterns(m: m)
                default:
                    if m.status != "failed" {
                        StepTimeline(m: m)
                        MaterialStudyData(m: m)
                    }
                }
            }
        } else {
            EmptyState(text: "This file is no longer in your library. It may be in Settings › Data and export › Recently Deleted.",
                       actionTitle: "Open Recently Deleted") { model.go(.settings(.data)) }
        }
    }
}

private struct MaterialHeader: View {
    @Environment(AppModel.self) var model
    let m: Material

    var body: some View {
        let course = m.courseId.flatMap { model.store.course($0) }
        VStack(alignment: .leading, spacing: 8) {
            Text(m.title).font(.stHeading).textSelection(.enabled)
            HStack(spacing: 10) {
                if let c = course {
                    Button { model.openCourse(c.id, tab: .materials) } label: {
                        HStack(spacing: 5) { CourseDot(color: c.color); Text(c.displayName).font(.stBody) }
                    }.buttonStyle(.plain)
                } else {
                    Button("File under a course") { model.go(.inbox(.files)) }.buttonStyle(.borderless)
                }
                Picker("Role", selection: Binding(get: { m.role }, set: { r in
                    model.run("\(m.title) is now a \(r.label.lowercased()).") { try model.store.updateMaterial(m.id, role: r); return nil }
                })) { ForEach(MaterialRole.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().frame(width: 130)
                if let p = m.processedAt { Chip(text: "Processed \(RelativeTime.describe(p))", systemImage: "checkmark") }
                Spacer()
                Button("Open file") { if let u = fileURL { NSWorkspace.shared.open(u) } }.buttonStyle(QuietButtonStyle()).disabled(fileURL == nil)
                Button("Show in Finder") { if let u = fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                    .buttonStyle(QuietButtonStyle()).disabled(fileURL == nil)
            }
        }
    }

    var fileURL: URL? { m.storedPath.map { model.store.paths.absolute($0) } }
}

/// A file that couldn't be read: the reason and a way forward.
private struct MaterialProblem: View {
    @Environment(AppModel.self) var model
    let m: Material

    var body: some View {
        Panel {
            Label(m.status == "needs_ocr" ? "No text could be read from this file" : "This file couldn't be read", systemImage: "exclamationmark.triangle.fill")
                .font(.stBodyStrong).foregroundStyle(Theme.attention)
            if let d = m.statusDetail { Text(d).font(.stSmall).foregroundStyle(Theme.textSecondary) }
            Text(m.status == "needs_ocr" ? "Scanned pages are read with on-device text recognition. A sharper scan or an exported PDF usually works."
                                         : "Try reading it again, or export it again as PDF and drop that in instead.")
                .font(.stSmall).foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Try reading again") { retry() }.buttonStyle(PrimaryButtonStyle())
                Button("Delete") { model.run("Deleted \(m.title).") { try model.store.trashMaterial(m.id) }; model.go(.study(.lectures), replace: true) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    /// Imports the stored file again as a fresh material; the old one goes to Recently Deleted.
    func retry() {
        guard let sp = m.storedPath else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(UUID().uuidString)-\(m.originalFilename)")
        do {
            try FileManager.default.copyItem(at: model.store.paths.absolute(sp), to: tmp)
            _ = try model.store.trashMaterial(m.id)
            switch model.store.importMaterial(from: tmp, courseId: m.courseId, role: m.role) {
            case .imported(let id, _): model.refresh(); model.openMaterial(id); model.show("Read \(m.title) again.")
            case .duplicate(let id, _): model.refresh(); model.openMaterial(id)
            case .failed(let msg): model.refresh(); model.show(msg, error: true)
            }
            try? FileManager.default.removeItem(at: tmp)
        } catch { model.fail(error) }
    }
}

/// Recall → Learn → Write → Test as a vertical timeline: the next step is expanded with its one primary action,
/// finished steps collapse to a summary line (§7.3 Study).
struct StepTimeline: View {
    @Environment(AppModel.self) var model
    let m: Material

    struct Step: Identifiable {
        var id: Int
        var title: String
        var detail: String
        var summary: String?
        var done: Bool
    }

    var body: some View {
        let store = model.store
        let sessions = store.sessions(materialId: m.id, limit: 50)
        let concepts = store.concepts(materialId: m.id)
        let sheet = store.notes(materialId: m.id, kind: "cornell_sheet").first
        let captures = store.handwritingCaptures(materialId: m.id)
        let cards = store.cards(status: "active", materialId: m.id)
        let done: (String) -> Bool = { kind in sessions.contains { $0.kind == kind } }
        let recall = sessions.first { $0.kind == "recall" && ($0.itemsTotal ?? 0) > 0 }
        let steps = [
            Step(id: 1, title: "Recall", detail: "Write what you remember before looking. Claude compares it with the lecture.",
                 summary: recall.map { "Recalled \($0.itemsCorrect ?? 0) of \($0.itemsTotal ?? 0) concepts" } ?? "Recall session done", done: done("recall")),
            Step(id: 2, title: "Learn", detail: "Claude reads the lecture and builds concepts, questions and your Cornell sheet.",
                 summary: "\(concepts.count) concepts · \(cards.count) cards", done: m.processedAt != nil),
            Step(id: 3, title: "Write", detail: "Fill the sheet by hand from memory, then photograph it for a gap check.",
                 summary: "\(captures.count) photo\(captures.count == 1 ? "" : "s") checked", done: !captures.isEmpty),
            Step(id: 4, title: "Test", detail: "\(cards.count) cards from this lecture, mixed with others for interleaving.",
                 summary: "Reviewed or quizzed", done: done("quiz") || done("review")),
        ]
        // One primary action: the first step that isn't done, with Learn before Recall for an unprocessed lecture.
        let active = m.processedAt == nil ? 2 : (steps.first { !$0.done }?.id ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        marker(step, active: step.id == active)
                        if step.id < 4 { Rectangle().fill(Theme.hairline).frame(width: 2).frame(maxHeight: .infinity) }
                    }.frame(width: 24)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.title).font(step.id == active ? .stBodyStrong : .stBody)
                            .foregroundStyle(step.done || step.id == active ? Theme.textPrimary : Theme.textSecondary)
                        if step.id == active {
                            Text(step.detail).font(.stSmall).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) { actions(step.id, sheet: sheet) }.padding(.top, 4)
                        } else if step.done, let s = step.summary {
                            Text(s).font(.stSmall).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.bottom, 18)
                    Spacer()
                    if step.id != active && step.done {
                        Menu { actions(step.id, sheet: sheet) } label: { Text("Again") }.menuStyle(.borderlessButton).fixedSize().font(.stSmall)
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.hairline))
    }

    @ViewBuilder func marker(_ step: Step, active: Bool) -> some View {
        ZStack {
            Circle().fill(active ? Theme.textPrimary : step.done ? Theme.success.opacity(0.18) : Theme.fillSubtle)
            if step.done && !active {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.success)
            } else {
                Text("\(step.id)").font(.stSmallStrong).foregroundStyle(active ? Theme.canvas : Theme.textSecondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel(step.done ? "\(step.title), done" : step.title)
    }

    @ViewBuilder func actions(_ id: Int, sheet: Note?) -> some View {
        switch id {
        case 1:
            ClaudeButton(task: .recall) { model.jobs.run(.recall, material: m.id) }.buttonStyle(PrimaryButtonStyle())
                .disabled(m.processedAt == nil)
        case 2:
            if m.processedAt == nil {
                ClaudeButton(task: .process) { model.jobs.run(.process, material: m.id) }.buttonStyle(PrimaryButtonStyle())
            } else if let c = m.courseId {
                Button("Open concepts") { model.openCourse(c, tab: .concepts) }.buttonStyle(QuietButtonStyle())
                ClaudeButton(task: .process) { model.jobs.run(.process, material: m.id) }.buttonStyle(.borderless)
            }
        case 3:
            if let sheet { Button("Print sheet") { model.exportSheet(sheet, print: true) }.buttonStyle(PrimaryButtonStyle()) }
            Button("Check my notes") { model.handwritingMaterialId = m.id }.buttonStyle(QuietButtonStyle())
        default:
            Button("Start review") { model.startReview(courseId: m.courseId) }.buttonStyle(PrimaryButtonStyle())
            ClaudeButton(task: .quiz) { model.jobs.run(.quiz, material: m.id) }.buttonStyle(.borderless)
            ClaudeButton(task: .practice) { model.jobs.run(.practice, material: m.id) }.buttonStyle(.borderless)
        }
    }
}

/// What this file has produced: concepts, cards, sessions and Claude's notes.
private struct MaterialStudyData: View {
    @Environment(AppModel.self) var model
    let m: Material
    @State private var showAllConcepts = false

    var body: some View {
        let store = model.store
        let concepts = store.concepts(materialId: m.id)
        let cards = store.cards(status: nil, materialId: m.id)
        let sessions = store.sessions(materialId: m.id, limit: 50)
        let notes = store.notes(materialId: m.id).filter { $0.kind != "cornell_sheet" }
        VStack(alignment: .leading, spacing: 22) {
            if !concepts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Concepts from this file · \(concepts.count)", trailing: m.courseId.map { cid in
                        AnyView(Button("In the course") { model.openCourse(cid, tab: .concepts) }.buttonStyle(.borderless).font(.stSmall))
                    })
                    ForEach(showAllConcepts ? concepts : Array(concepts.prefix(10))) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.name).font(.stBodyStrong)
                            Text(c.definition).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        }
                    }
                    if concepts.count > 10 && !showAllConcepts {
                        Button("Show all \(concepts.count)") { showAllConcepts = true }.buttonStyle(.borderless).font(.stSmall)
                    }
                }
            }
            if !cards.isEmpty {
                let proposed = cards.filter { $0.status == "proposed" }.count
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Cards from this file · \(cards.count)", trailing: AnyView(HStack {
                        if proposed > 0 { Button("Approve \(proposed)") { model.go(.inbox(.cards)) }.buttonStyle(.borderless).font(.stSmall) }
                        if let cid = m.courseId { Button("In the course") { model.openCourse(cid, tab: .cards) }.buttonStyle(.borderless).font(.stSmall) }
                    }))
                    ForEach(cards.prefix(6)) { c in
                        HStack { Text(c.front).font(.stBody).lineLimit(1); Spacer(); if c.status == "proposed" { Chip(text: "Proposed") } }
                    }
                }
            }
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Sessions")
                    ForEach(sessions.prefix(8)) { s in
                        HStack(alignment: .top) {
                            Text(s.kind.capitalized).font(.stSmallStrong).frame(width: 90, alignment: .leading)
                            Text(s.summary ?? "").font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(3)
                            Spacer()
                            Text(Formatters.day(s.startedAt, tz: model.tz)).font(.stSmall).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            if !notes.isEmpty { NotesList(notes: notes, title: "Gap reports and notes") }
        }
    }
}

private struct NotesList: View {
    var notes: [Note]
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            ForEach(notes) { n in
                DisclosureGroup {
                    Text(LocalizedStringKey(n.contentMd)).font(.stBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text(n.title).font(.stBody) }
            }
        }
    }
}

/// Syllabi, briefs and rubrics: the deadlines taken from them, and the assignments they belong to.
private struct MaterialDeadlines: View {
    @Environment(AppModel.self) var model
    let m: Material

    var body: some View {
        let store = model.store
        let extracted = store.assignments(sourceMaterialId: m.id)
        let uses = store.assignments(rubricMaterialId: m.id)
        let courses = store.courseMap()
        VStack(alignment: .leading, spacing: 22) {
            Panel {
                SectionHeader(title: "Deadlines from this file · \(extracted.count)")
                if extracted.isEmpty {
                    Text("Claude can read this \(m.role.label.lowercased()) and list every graded item with its date and weight, for you to confirm.")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
                ForEach(extracted) { a in
                    Button { a.confirmed ? model.openAssignment(a.id) : model.go(.inbox(.deadlines)) } label: {
                        HStack {
                            AssignmentLine(a: a, courses: courses)
                            if !a.confirmed { Chip(text: "To confirm", urgent: true) }
                        }
                    }.buttonStyle(.plain)
                }
                ClaudeButton(task: .extractDeadlines) { model.jobs.run(.extractDeadlines, material: m.id) }
                    .buttonStyle(extracted.isEmpty ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(QuietButtonStyle()))
            }
            if !uses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Used as the rubric or brief for")
                    ForEach(uses) { a in
                        Button { model.openAssignment(a.id) } label: { AssignmentLine(a: a, courses: courses) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Past exams: the patterns Claude found, and practice in the same style.
private struct MaterialExamPatterns: View {
    @Environment(AppModel.self) var model
    let m: Material

    var body: some View {
        let patterns = model.store.notes(materialId: m.id, kind: "exam_patterns")
        VStack(alignment: .leading, spacing: 18) {
            Panel {
                SectionHeader(title: "Exam patterns")
                if let p = patterns.first {
                    Text(LocalizedStringKey(p.contentMd)).font(.stBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Claude maps each question to its topic, marks and command word, then writes practice questions in the same style.")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
                ClaudeButton(task: .examPatterns) { model.jobs.run(.examPatterns, material: m.id) }
                    .buttonStyle(patterns.isEmpty ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(QuietButtonStyle()))
            }
        }
    }
}
