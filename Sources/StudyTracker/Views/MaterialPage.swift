import SwiftUI
import AppKit
import StudyCore

/// The one home for any course file (`material/{id}`): what the file is and why, and what it gives the course: the
/// problems split out of a problem set or exam, the deadlines and weekly plan read from a syllabus, what a lecture
/// covers, or why a file isn't used.
struct MaterialPage: View {
    @Environment(AppModel.self) var model
    var materialId: Int

    var body: some View {
        let _ = model.revision
        if let m = model.store.material(materialId) {
            VStack(alignment: .leading, spacing: 22) {
                FileHeader(m: m)
                if m.status == "failed" || m.status == "needs_ocr" {
                    FileProblem(m: m)
                } else {
                    switch m.group {
                    case .practice, .exams: FileProblems(m: m)
                    case .info: FileCourseInfo(m: m)
                    case .path: FileOutline(m: m)
                    case .notUsed: FileNotUsed(m: m)
                    }
                }
                EarlierStudyData(m: m)
            }
        } else {
            EmptyState(text: "This file is no longer in your library. It may be in Settings › Data and export › Recently Deleted.",
                       actionTitle: "Open Recently Deleted") { model.go(.settings(.data)) }
        }
    }
}

private struct FileHeader: View {
    @Environment(AppModel.self) var model
    let m: Material

    var body: some View {
        let course = m.courseId.flatMap { model.store.course($0) }
        VStack(alignment: .leading, spacing: 8) {
            Text(m.title).font(.stHeading).textSelection(.enabled)
            HStack(spacing: 10) {
                if let c = course {
                    Button { model.openCourse(c.id, tab: .files) } label: {
                        HStack(spacing: 5) { CourseDot(color: c.color); Text(c.displayName).font(.stBody) }
                    }.buttonStyle(.plain)
                } else {
                    Button("File under a course") { model.go(.needsLook) }.buttonStyle(.borderless)
                }
                UseChip(file: m)
                if let t = m.taughtOn {
                    Text("Taught \(Formatters.day(t.at(LocalTime(hour: 12, minute: 0), tz: model.tz), tz: model.tz))")
                        .font(.stSmall).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button("Open file") { if let u = fileURL { NSWorkspace.shared.open(u) } }.buttonStyle(QuietButtonStyle()).disabled(fileURL == nil)
                Button("Show in Finder") { if let u = fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                    .buttonStyle(QuietButtonStyle()).disabled(fileURL == nil)
            }
            if m.roleSource != "user", let reason = m.sortReason {
                Text(reason).font(.stSmall).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    var fileURL: URL? { m.storedPath.map { model.store.paths.absolute($0) } }
}

/// A file that couldn't be read: the reason and a way forward.
private struct FileProblem: View {
    @Environment(AppModel.self) var model
    let m: Material

    var body: some View {
        Panel {
            Label(m.status == "needs_ocr" ? "No text could be read from this file" : "This file couldn't be read", systemImage: "exclamationmark.triangle.fill")
                .font(.stBodyStrong).foregroundStyle(Theme.attention)
            if let d = m.statusDetail { Text(d).font(.stSmall).foregroundStyle(Theme.textSecondary) }
            Text(m.status == "needs_ocr" ? "Scanned pages are read with on-device text recognition. A sharper scan or an exported PDF usually works."
                                         : "Try reading it again, or export it again as PDF and drop that in instead. Until then it isn't used.")
                .font(.stSmall).foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Try reading again") { retry() }.buttonStyle(PrimaryButtonStyle())
                Button("Delete") {
                    let course = m.courseId
                    model.run("Deleted \(m.title).") { try model.store.trashMaterial(m.id) }
                    if let course { model.openCourse(course, tab: .files) }
                }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    /// Imports the stored file again as a fresh material; the old one goes to Recently Deleted.
    func retry() {
        guard let sp = m.storedPath else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(UUID().uuidString)-\(m.originalFilename ?? URL(fileURLWithPath: sp).lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: model.store.paths.absolute(sp), to: tmp)
            _ = try model.store.trashMaterial(m.id)
            let role = m.roleSource == "user" ? m.role : nil
            switch model.store.importMaterial(from: tmp, courseId: m.courseId, role: role) {
            case .imported(let id, _): model.refresh(); model.openMaterial(id); model.show("Read \(m.title) again.")
            case .duplicate(let id, _): model.refresh(); model.openMaterial(id)
            case .failed(let msg): model.refresh(); model.show(msg, error: true)
            }
            try? FileManager.default.removeItem(at: tmp)
        } catch { model.fail(error) }
    }
}

/// Problem sets, class examples and past exams: their problems, word for word, with solutions when the course gave them.
private struct FileProblems: View {
    @Environment(AppModel.self) var model
    let m: Material
    @State private var showAll = false

    var body: some View {
        let store = model.store
        // The course's own problems. Questions an earlier version wrote from this file are listed with the rest of its
        // earlier data.
        let items = store.practiceItems(materialId: m.id).filter { $0.source == "course" }
        let answers = store.materials(courseId: m.courseId).first { $0.pairsWith == m.id }
        let sheet = m.pairsWith.flatMap { store.material($0) }
        VStack(alignment: .leading, spacing: 8) {
            if let sheet {
                Panel {
                    Text("These are the solutions to \(sheet.title). They're shown with its problems.").font(.stBody)
                    Button("Open \(sheet.title)") { model.openMaterial(sheet.id) }.buttonStyle(QuietButtonStyle())
                }
            } else {
                SectionHeader(title: "\(m.role == .pastExam ? "Questions" : "Problems") · \(items.count)")
                Text(caption(items: items, answers: answers)).font(.stSmall).foregroundStyle(Theme.textTertiary)
                if items.isEmpty {
                    EmptyState(text: "No problems could be found in this file. If it isn't really practice, tap its chip above.")
                }
                ForEach(showAll ? items : Array(items.prefix(12))) { item in ProblemRow(item: item) }
                if items.count > 12 && !showAll {
                    Button("Show all \(items.count)") { showAll = true }.buttonStyle(.borderless).font(.stSmall)
                }
            }
        }
    }

    func caption(items: [PracticeItem], answers: Material?) -> String {
        var parts = [m.role == .pastExam ? "They come up in sessions as exam-style practice, and their marks show what earns marks."
                                         : "They come up in your sessions as practice in your course's own style. They're never turned into notes."]
        if let answers { parts.append("Solutions from \(answers.title).") }
        if items.contains(where: \.isUnlabelled) { parts.append("Free AI adds each one's kind and topic.") }
        return parts.joined(separator: " ")
    }
}

private struct ProblemRow: View {
    let item: PracticeItem
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.number.map { "#\($0)" } ?? "•").font(.stSmallStrong).foregroundStyle(Theme.textTertiary).frame(width: 30, alignment: .leading)
                Text(item.promptMd).font(.stBody).lineLimit(open ? nil : 2).textSelection(.enabled)
                Spacer(minLength: 8)
                if item.kind != "other" { Chip(text: item.kind.capitalized) }
                if let m = item.marks { Chip(text: "\(m == m.rounded() ? String(Int(m)) : String(m)) marks") }
            }
            if open {
                if let t = item.topicLabel { Text("Practises \(t)").font(.stSmall).foregroundStyle(Theme.textTertiary).padding(.leading, 38) }
                if let s = item.solutionMd {
                    Text("Solution").font(.stSmallStrong).foregroundStyle(Theme.textTertiary).padding(.leading, 38)
                    Text(s).font(.stBody).foregroundStyle(Theme.textSecondary).textSelection(.enabled).padding(.leading, 38)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.fillSubtle))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: Theme.motionFast)) { open.toggle() } }
        .accessibilityHint(open ? "Hide the solution" : "Show the solution")
    }
}

/// Syllabi, briefs and rubrics: the deadlines taken from them, the weekly plan kept for the course builder, and the
/// assignments they belong to.
private struct FileCourseInfo: View {
    @Environment(AppModel.self) var model
    let m: Material

    var body: some View {
        let store = model.store
        let extracted = store.assignments(sourceMaterialId: m.id)
        let uses = store.assignments(rubricMaterialId: m.id)
        let courses = store.courseMap()
        let scan = store.materialScan(materialId: m.id, kind: "syllabus").flatMap { JSON.parse($0) as? [String: Any] }
        VStack(alignment: .leading, spacing: 22) {
            Panel {
                SectionHeader(title: "Deadlines from this file · \(extracted.count)")
                if extracted.isEmpty {
                    Text(m.readState == "pending" ? "Free AI reads this \(m.role.label.lowercased()) for graded items, for you to confirm."
                                                  : "No graded items were found here.")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
                ForEach(extracted) { a in
                    Button { a.confirmed ? model.openAssignment(a.id) : model.go(.needsLook) } label: {
                        HStack {
                            AssignmentLine(a: a, courses: courses)
                            if !a.confirmed { Chip(text: "To confirm", urgent: true) }
                        }
                    }.buttonStyle(.plain)
                }
                Button("Read it again") { model.jobs.run(.extractDeadlines, material: m.id) }.buttonStyle(QuietButtonStyle())
            }
            if let scan, !((scan["schedule"] as? [Any])?.isEmpty ?? true) || !((scan["outcomes"] as? [Any])?.isEmpty ?? true) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "What the course builder learns from it")
                    if let outcomes = scan["outcomes"] as? [String], !outcomes.isEmpty {
                        Text("Learning outcomes").font(.stSmallStrong).foregroundStyle(Theme.textTertiary)
                        ForEach(outcomes.prefix(12), id: \.self) { Text("• \($0)").font(.stBody) }
                    }
                    if let weeks = scan["schedule"] as? [[String: Any]], !weeks.isEmpty {
                        Text("Weekly plan").font(.stSmallStrong).foregroundStyle(Theme.textTertiary).padding(.top, 4)
                        ForEach(Array(weeks.prefix(20).enumerated()), id: \.offset) { _, w in
                            HStack(alignment: .firstTextBaseline) {
                                Text((w["week"] as? Int).map { "Week \($0)" } ?? (w["date"] as? String ?? "")).font(.stSmall)
                                    .foregroundStyle(Theme.textTertiary).frame(width: 70, alignment: .leading)
                                Text(w["topic"] as? String ?? "").font(.stBody)
                            }
                        }
                    }
                }
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

/// Lectures and readings: what's in them, at a glance. They shape the path; they're never turned into notes.
private struct FileOutline: View {
    @Environment(AppModel.self) var model
    let m: Material

    var body: some View {
        let chunks = model.store.chunks(materialId: m.id)
        let headings = chunks.compactMap { c -> (String, String)? in
            guard let h = c.heading?.nilIfEmpty else { return nil }
            return (c.locator, h)
        }
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "What's in it · \(chunks.count) \(m.kind == "slides" ? "slides" : "parts")")
            Text("Lectures and readings show your course's topics, when it teaches them, the words it uses and what it stresses. Your notebook and lessons come from the course's path, with this file's angle.")
                .font(.stSmall).foregroundStyle(Theme.textTertiary)
            ForEach(Array(dedupe(headings).prefix(24).enumerated()), id: \.offset) { _, h in
                HStack(alignment: .firstTextBaseline) {
                    Text(h.0).font(.stSmall).foregroundStyle(Theme.textTertiary).frame(width: 64, alignment: .leading)
                    Text(h.1).font(.stBody).lineLimit(1)
                }
            }
        }
    }

    /// Repeated slide titles ("Overbooking (cont.)") show once.
    func dedupe(_ hs: [(String, String)]) -> [(String, String)] {
        var seen = Set<String>()
        return hs.filter { seen.insert($0.1.lowercased().replacingOccurrences(of: #"\s*\(cont.*\)$"#, with: "", options: .regularExpression)).inserted }
    }
}

private struct FileNotUsed: View {
    let m: Material
    var body: some View {
        Panel {
            Text("Kept for reference and never used for your notebook, lessons or practice.").font(.stBody)
            Text(m.excluded ? "You set it aside. Tap its chip above to use it after all." : "It doesn't look like course material. Tap its chip above if it is.")
                .font(.stSmall).foregroundStyle(Theme.textSecondary)
        }
    }

    func counted(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

/// Concepts, cards and notes made from this file by earlier versions of the app, kept and out of the way.
private struct EarlierStudyData: View {
    @Environment(AppModel.self) var model
    let m: Material
    @State private var open = false

    var body: some View {
        let store = model.store
        let concepts = store.concepts(materialId: m.id)
        let cards = store.cards(status: nil, materialId: m.id)
        let notes = store.notes(materialId: m.id)
        let questions = store.practiceItems(materialId: m.id).filter { $0.source == "generated" }
        if !concepts.isEmpty || !cards.isEmpty || !notes.isEmpty || !questions.isEmpty {
            DisclosureGroup("From earlier versions: " + [counted(concepts.count, "concept"), counted(questions.count, "question"),
                                                         counted(cards.count, "card"), counted(notes.count, "note")].compactMap { $0 }.joined(separator: ", "),
                            isExpanded: $open) {
                VStack(alignment: .leading, spacing: 6) {
                    if !questions.isEmpty {
                        Text("\(questions.count) practice question\(questions.count == 1 ? "" : "s") written from this file. They stay in your practice.")
                            .font(.stSmall).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(concepts.prefix(30)) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.name).font(.stBodyStrong)
                            Text(c.definition).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        }
                    }
                    ForEach(notes.filter { $0.kind != "cornell_sheet" }) { n in
                        DisclosureGroup {
                            Text(LocalizedStringKey(n.contentMd)).font(.stBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } label: { Text(n.title).font(.stBody) }
                    }
                    if !cards.isEmpty { Text("The cards are in your reviews.").font(.stSmall).foregroundStyle(Theme.textTertiary) }
                }.padding(.top, 6)
            }
            .font(.stSmall).foregroundStyle(Theme.textSecondary)
        }
    }

    func counted(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
