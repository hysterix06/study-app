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
        let store = model.store
        var out: [PaletteItem] = []
        if let next = store.nextSessionPlan().primary {
            out.append(PaletteItem(title: "Start: " + SessionCopy.describe(next, store: store), subtitle: "Session", icon: "play.fill") { model.startSession(next) })
        }
        out += [
            PaletteItem(title: "Home", subtitle: "Go to", icon: "house") { model.go(.home) },
            PaletteItem(title: "Calendar", subtitle: "Schedule", icon: "calendar") { model.go(.calendar(.week, nil)) },
            PaletteItem(title: "Assignments", subtitle: "Schedule", icon: "checklist") { model.go(.assignments) },
            PaletteItem(title: "Needs a look", subtitle: "Go to", icon: "tray") { model.go(.needsLook) },
            PaletteItem(title: "Just review", subtitle: "Session", icon: "rectangle.stack") { model.startReview() },
        ]
        for p in SettingsPane.allCases { out.append(PaletteItem(title: p.title, subtitle: "Settings", icon: p.icon) { model.go(.settings(p)) }) }
        out += [
            PaletteItem(title: "Add assignment", subtitle: "Action", icon: "plus") { model.go(.assignments); model.focusQuickAdd += 1 },
            PaletteItem(title: "Import files", subtitle: "Action", icon: "square.and.arrow.down") { model.chooseFilesToImport() },
            PaletteItem(title: "Sync calendars and Moodle", subtitle: "Action", icon: "arrow.clockwise") {
                Task { await model.syncFeeds(silent: false); await model.moodle.sync(silent: false) }
            },
            PaletteItem(title: "New AI chat", subtitle: "AI", icon: "bubble.left.and.bubble.right") { model.newChat() },
            PaletteItem(title: "Open my AI app", subtitle: "AI", icon: "arrow.up.forward.app") { model.openAIApp() },
        ]
        let courses = store.courses()
        for c in courses {
            out.append(PaletteItem(title: c.names.joined(separator: " · "), subtitle: "Course", icon: "books.vertical") { model.openCourse(c.id) })
            out.append(PaletteItem(title: "Write notebook · \(c.displayName)", subtitle: "Session", icon: "pencil.and.outline") {
                let left = store.topics(courseId: c.id).filter { !$0.inNotebook && $0.userState != "hidden" }.map(\.id)
                if left.isEmpty { model.show("Every page of \(c.displayName)'s notebook is written.") }
                else { model.startSession(SessionPick(kind: .notebook, courseId: c.id, topicIds: left, minutes: 25, score: 1)) }
            })
            out.append(PaletteItem(title: "Rebuild \(c.displayName) with Claude", subtitle: "Course builder", icon: "sparkles") { model.jobs.buildWithBuilder(courseId: c.id) })
            let numbers = store.topicNumbers(courseId: c.id)
            for t in store.topics(courseId: c.id) {
                out.append(PaletteItem(title: "\(numbers[t.id].map { "\($0) " } ?? "")\(t.title)", subtitle: "Topic · \(c.displayName)", icon: "circle.dotted") { model.go(.topic(t.id)) })
            }
        }
        let map = store.courseMap()
        for a in store.assignments().filter({ $0.isOpen }) {
            out.append(PaletteItem(title: a.title, subtitle: "Assignment · \(a.courseId.flatMap { map[$0]?.displayName } ?? "")", icon: "checklist") { model.openAssignment(a.id) })
        }
        for m in store.materials() where m.courseId != nil {
            out.append(PaletteItem(title: m.title, subtitle: "\(m.role.label) · \(m.courseId.flatMap { map[$0]?.displayName } ?? "")", icon: "doc") { model.openMaterial(m.id) })
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
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Jump to a course, topic, file or action", text: $query).textFieldStyle(.plain).font(.stBodyStrong)
                    .focused($focused)
                    .onSubmit { if list.indices.contains(selection) { execute(list[selection]) } }
                    .onChange(of: query) { selection = 0 }
            }.padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 18).foregroundStyle(Theme.textSecondary)
                            Text(item.title).font(.stBody).lineLimit(1)
                            Spacer()
                            Text(item.subtitle).font(.stSmall).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Theme.corner(6)).fill(i == selection ? Theme.textPrimary.opacity(0.08) : Theme.clear))
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

/// Menu bar: the next session with Start, reviews due, and what's due soon, without opening the app.
struct MenuBarView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let _ = model.revision
        let store = model.store
        let next = store.nextSessionPlan().primary
        let snap = store.todaySnapshot()
        let courses = store.courseMap()
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT SESSION").font(.stSmallStrong).foregroundStyle(Theme.textTertiary)
                if let next {
                    Text(SessionCopy.describe(next, store: store)).font(.stBodyStrong).fixedSize(horizontal: false, vertical: true)
                    Text(SessionReasons.line(next, store: store)).font(.stSmall).foregroundStyle(Theme.textSecondary)
                    Button("Start") { show(); model.startSession(next) }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Text("You're up to date.").font(.stBody).foregroundStyle(Theme.textSecondary)
                }
            }
            if let n = snap.nextClass {
                Divider()
                HStack(spacing: 6) {
                    CourseDot(color: n.courseId.flatMap { courses[$0]?.color })
                    Text(n.title).font(.stSmall).lineLimit(1)
                    Spacer()
                    Text(RelativeTime.describe(n.start)).font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
            }
            if !snap.dueSoon.isEmpty {
                Divider()
                Text("DUE SOON").font(.stSmallStrong).foregroundStyle(Theme.textTertiary)
                ForEach(snap.dueSoon.prefix(4)) { a in
                    HStack(spacing: 6) {
                        CourseDot(color: a.courseId.flatMap { courses[$0]?.color })
                        Text(a.title).font(.stSmall).lineLimit(1)
                        Spacer()
                        Text(a.dueAt.map { RelativeTime.describe($0) } ?? "").font(.stSmall).monospacedDigit()
                            .foregroundStyle(a.isOverdue(now: Date()) ? Theme.attention : Theme.textSecondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Study Tracker") { show() }
                Spacer()
                if snap.cardsDue > 0 { Button("Review \(snap.cardsDue)") { show(); model.startReview() } }
            }
            .font(.stSmall)
        }
        .padding(14).frame(width: 300)
    }

    func show() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
