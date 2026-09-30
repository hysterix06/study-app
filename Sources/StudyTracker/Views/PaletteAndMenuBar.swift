import SwiftUI
import StudyCore

struct PaletteItem: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var icon: String
    var run: () -> Void
}

/// ⌘K: jump to a course, screen, assignment or lecture, or run an action.
struct CommandPalette: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var items: [PaletteItem] {
        var out: [PaletteItem] = []
        for s in SidebarItem.sidebar { out.append(PaletteItem(title: s.title, subtitle: "Go to", icon: s.icon) { model.open(s) }) }
        out.append(PaletteItem(title: "Settings", subtitle: "Go to", icon: "gearshape") { model.go(.settings(.general)) })
        out += [
            PaletteItem(title: "Add assignment", subtitle: "Action", icon: "plus") { model.go(.assignments); model.focusQuickAdd += 1 },
            PaletteItem(title: "Import files", subtitle: "Action", icon: "square.and.arrow.down") { model.chooseFilesToImport() },
            PaletteItem(title: "Start review", subtitle: "Action", icon: "rectangle.stack") { model.startReview() },
            PaletteItem(title: "Plan study blocks", subtitle: "Action", icon: "wand.and.stars") { model.planStudy() },
            PaletteItem(title: "Sync calendars and Moodle", subtitle: "Action", icon: "arrow.clockwise") {
                Task { await model.syncFeeds(silent: false); await model.moodle.sync(silent: false) }
            },
            PaletteItem(title: "Copy weekly plan prompt", subtitle: "Claude", icon: "sparkles") { model.copyPrompt("weekly_plan", [:]) },
            PaletteItem(title: "Open Claude", subtitle: "Claude", icon: "sparkles") { model.openClaude() },
        ]
        let courses = model.store.courses()
        for c in courses { out.append(PaletteItem(title: c.names.joined(separator: " · "), subtitle: "Course", icon: "books.vertical") { model.openCourse(c.id) }) }
        let map = model.store.courseMap()
        for a in model.store.assignments().filter({ $0.isOpen }) {
            out.append(PaletteItem(title: a.title, subtitle: "Assignment · \(a.courseId.flatMap { map[$0]?.displayName } ?? "")", icon: "checklist") { model.openAssignment(a.id) })
        }
        for m in model.store.materials().prefix(60) where m.courseId != nil {
            out.append(PaletteItem(title: m.title, subtitle: "Lecture · \(m.courseId.flatMap { map[$0]?.displayName } ?? "")", icon: "doc") { model.openMaterial(m.id) })
        }
        return out
    }

    var filtered: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(items.prefix(12)) }
        let words = q.split(separator: " ")
        return items.filter { i in
            let hay = (i.title + " " + i.subtitle).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }.prefix(12).map { $0 }
    }

    var body: some View {
        let list = filtered
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                TextField("Jump to a course, assignment or action", text: $query).textFieldStyle(.plain).font(.stBodyStrong)
                    .focused($focused)
                    .onSubmit { if list.indices.contains(selection) { execute(list[selection]) } }
                    .onChange(of: query) { selection = 0 }
            }.padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 18).foregroundStyle(Theme.secondaryText)
                            Text(item.title).font(.stBody).lineLimit(1)
                            Spacer()
                            Text(item.subtitle).font(.stSmall).foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(i == selection ? Color.primary.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { execute(item) }
                    }
                }.padding(6)
            }.frame(height: 360)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    func execute(_ item: PaletteItem) { dismiss(); DispatchQueue.main.async { item.run() } }
}

/// Menu bar: what's next without opening the app.
struct MenuBarView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let _ = model.revision
        let snap = model.store.todaySnapshot()
        let courses = model.store.courseMap()
        let tz = model.tz
        VStack(alignment: .leading, spacing: 10) {
            if let n = snap.nextClass {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEXT CLASS").font(.stSmallStrong).foregroundStyle(Theme.tertiaryText)
                    HStack(spacing: 6) { CourseDot(color: n.courseId.flatMap { courses[$0]?.color }); Text(n.title).font(.stBodyStrong).lineLimit(1) }
                    Text("\(Formatters.time(n.start, tz: tz)) · \(n.location ?? "") · \(RelativeTime.describe(n.start))").font(.stSmall).foregroundStyle(Theme.secondaryText)
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SUGGESTED").font(.stSmallStrong).foregroundStyle(Theme.tertiaryText)
                Text(snap.suggested.title).font(.stBody).fixedSize(horizontal: false, vertical: true)
            }
            if !snap.dueSoon.isEmpty {
                Divider()
                Text("DUE SOON").font(.stSmallStrong).foregroundStyle(Theme.tertiaryText)
                ForEach(snap.dueSoon.prefix(4)) { a in
                    HStack(spacing: 6) {
                        CourseDot(color: a.courseId.flatMap { courses[$0]?.color })
                        Text(a.title).font(.stSmall).lineLimit(1)
                        Spacer()
                        Text(a.dueAt.map { RelativeTime.describe($0) } ?? "").font(.stSmall).monospacedDigit()
                            .foregroundStyle(a.isOverdue(now: Date()) ? Theme.accent : Theme.secondaryText)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Study Tracker") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                if snap.cardsDue > 0 {
                    Button("Review \(snap.cardsDue)") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); model.startReview() }
                }
            }
            .font(.stSmall)
        }
        .padding(14).frame(width: 300)
    }
}
