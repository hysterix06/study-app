import SwiftUI
import AppKit
import StudyCore

/// A course's files, grouped by how they're used. Files sort themselves; one tap on a file's chip says what it really is.
struct FilesTab: View {
    @Environment(AppModel.self) var model
    var course: Course

    var body: some View {
        let _ = model.revision
        let files = model.store.materials(courseId: course.id)
        let groups = Dictionary(grouping: files, by: \.group)
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary(groups, total: files.count)).font(.stBody).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Add files…") { model.chooseFilesToImport() }.buttonStyle(QuietButtonStyle())
            }
            if files.isEmpty {
                EmptyState(text: "Drop \(course.displayName)'s slides, problem sets, past exams and syllabus here. They sort themselves.")
            }
            ForEach(FileGroup.allCases) { g in
                if let list = groups[g], !list.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "\(g.title) · \(list.count)")
                        Text(g.explanation).font(.stSmall).foregroundStyle(Theme.textTertiary).padding(.bottom, 2)
                        ForEach(list) { m in FileRow(file: m) }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { model.importFiles($0, courseId: course.id) }
            return true
        }
    }

    /// "24 files: 15 shape your path, 6 practice, 1 past exam."
    func summary(_ groups: [FileGroup: [Material]], total: Int) -> String {
        guard total > 0 else { return "No files yet." }
        var parts: [String] = []
        if let n = groups[.path]?.count { parts.append("\(n) shape\(n == 1 ? "s" : "") your path") }
        if let n = groups[.practice]?.count { parts.append("\(n) for practice") }
        if let n = groups[.exams]?.count { parts.append("\(n) past exam\(n == 1 ? "" : "s")") }
        if let n = groups[.info]?.count { parts.append("\(n) course info") }
        if let n = groups[.notUsed]?.count { parts.append("\(n) not used") }
        return "\(total) file\(total == 1 ? "" : "s"): " + parts.joined(separator: ", ") + "."
    }
}

struct FileRow: View {
    @Environment(AppModel.self) var model
    let file: Material

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title).font(.stBody).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.stSmall).foregroundStyle(unreadable ? Theme.attention : Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            UseChip(file: file)
            Menu {
                Button("Open file") { if let p = file.storedPath { NSWorkspace.shared.open(model.store.paths.absolute(p)) } }
                Button("Show in Finder") {
                    if let p = file.storedPath { NSWorkspace.shared.activateFileViewerSelecting([model.store.paths.absolute(p)]) }
                }
                Menu("Move to course") {
                    ForEach(model.store.courses().filter { $0.id != file.courseId }) { c in
                        Button(c.displayName) {
                            model.run("Moved \(file.title) to \(c.displayName).") { try model.store.confirmMaterial(file.id, courseId: c.id); return nil }
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { model.run("Deleted \(file.title).") { try model.store.trashMaterial(file.id) } }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("More for \(file.title)")
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openMaterial(file.id) }
        .padding(10).background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.fillSubtle))
    }

    var unreadable: Bool { file.status == "failed" || file.status == "needs_ocr" }

    var detail: String {
        var parts: [String] = []
        if unreadable { parts.append(file.statusDetail?.nilIfEmpty ?? "Couldn't read this file, so it isn't used.") }
        else if file.excluded { parts.append("You set this aside.") }
        else if file.roleSource != "user", let reason = file.sortReason { parts.append(reason) }
        if let t = file.taughtOn { parts.append("Taught \(Formatters.day(t.at(LocalTime(hour: 12, minute: 0), tz: model.tz), tz: model.tz))") }
        if file.pairsWith != nil { parts.append("Solutions") }
        return parts.joined(separator: " · ")
    }

    var icon: String {
        switch file.kind {
        case "slides": return "rectangle.on.rectangle"
        case "pdf": return "doc.richtext"
        case "doc": return "doc.text"
        case "image": return "photo"
        default: return "text.alignleft"
        }
    }
}

/// What a file is, as a chip; tapping it says what it really is. The student's choice is final.
struct UseChip: View {
    @Environment(AppModel.self) var model
    let file: Material

    var unsure: Bool { file.roleSource != "user" && (file.roleConfidence ?? 1) < FileSorter.sureEnough && file.group != .notUsed }

    var body: some View {
        Menu {
            ForEach(FileGroup.allCases.filter { $0 != .notUsed }) { g in
                Section(g.title) {
                    ForEach(MaterialRole.allCases.filter { $0.group == g }) { r in
                        Button { set(r) } label: {
                            if file.group == g && file.role == r { Label(r.label, systemImage: "checkmark") } else { Text(r.label) }
                        }
                    }
                }
            }
            Divider()
            Button {
                model.run("Set aside \(file.title). It stays here and is never used.") { try model.store.setFileGroupUndoable(file.id, .notUsed) }
            } label: {
                if file.group == .notUsed { Label("Not used", systemImage: "checkmark") } else { Text("Not used") }
            }
            if unsure {
                Divider()
                Button("Looks right") { model.run("Kept \(file.title) as \(file.role.label.lowercased()).") { try model.store.confirmSort(file.id); return nil } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(file.group == .notUsed ? "Not used" : file.role.label)
                if unsure { Text("?").fontWeight(.semibold) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.stSmall)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(unsure ? Theme.attention : Theme.textSecondary)
            .background(RoundedRectangle(cornerRadius: Theme.corner(5)).fill(unsure ? Theme.attention.opacity(0.1) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner(5)).strokeBorder(Theme.hairline))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(unsure ? "Not sure what this is. Choose what it is, or keep the guess." : "What this file is, and how it's used")
        .accessibilityLabel("\(file.title) is \(file.group == .notUsed ? "not used" : file.role.label)\(unsure ? ", not sure" : "")")
    }

    func set(_ role: MaterialRole) {
        model.run("\(file.title) is now \(role.label.lowercased()).") { try model.store.setFileRoleUndoable(file.id, role) }
    }
}
