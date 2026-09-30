import SwiftUI
import AppKit
import StudyCore

@main
struct StudyTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model: AppModel? = AppDelegate.makeModel()

    var body: some Scene {
        Window("Study Tracker", id: "main") {
            Group {
                if let model {
                    RootView().environment(model).themed()
                } else {
                    Text(AppDelegate.openError ?? "The database could not be opened.").padding(40)
                }
            }
            .frame(minWidth: 980, minHeight: 640)
            .onOpenURL { url in if let r = Route(url: url) { model?.go(r) } }
        }
        .handlesExternalEvents(matching: [Route.scheme])
        .defaultSize(width: 1240, height: 820)
        .commands {
            if let model {
                CommandGroup(replacing: .newItem) {
                    Button("New Assignment") { model.go(.assignments); model.focusQuickAdd += 1 }.keyboardShortcut("n")
                    Button("Import Files…") { model.chooseFilesToImport() }.keyboardShortcut("o")
                }
                CommandGroup(replacing: .undoRedo) {
                    // A text field being edited keeps its own undo; otherwise ⌘Z walks back through recent writes.
                    Button(model.undoStack.last.map { "Undo \($0.label)" } ?? "Undo") {
                        if NSApp.keyWindow?.firstResponder is NSText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                        else { model.performUndo() }
                    }.keyboardShortcut("z")
                    Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }.keyboardShortcut("z", modifiers: [.command, .shift])
                }
                CommandMenu("Go") {
                    ForEach(Array(SidebarItem.numbered.enumerated()), id: \.element) { i, s in
                        Button(s.title) { model.open(s) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    }
                    Divider()
                    Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.canGoBack)
                    Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!model.canGoForward)
                    Divider()
                    Button("Command Palette") { model.showPalette = true }.keyboardShortcut("k")
                    Button("Connections") { model.go(.connections(nil)) }
                    Button("Claude Activity") { model.go(.activity(jobId: nil)) }
                }
                CommandMenu("Study") {
                    Button("Start Review") { model.startReview() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("Plan Study Blocks") { model.planStudy() }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Sync Calendars and Moodle") {
                        Task { await model.syncFeeds(silent: false); await model.moodle.sync(silent: false) }
                    }.keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
        }

        Settings {
            if let model { SettingsWindow().environment(model).themed() }
        }

        MenuBarExtra {
            if let model { MenuBarView().environment(model).themed() }
        } label: {
            Image(systemName: "brain")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openError: String?

    @MainActor
    static func makeModel() -> AppModel? {
        do {
            let store = try StudyStore.open()
            seedDefaults(store)
            // Launch arguments for demos and screenshots: -sampleData YES -route calendar/month
            if UserDefaults.standard.bool(forKey: "sampleData") && !SampleData.isLoaded(store) { try? SampleData.load(store) }
            let model = AppModel(store: store)
            // First launch opens setup; people who already have courses skip it.
            if !store.boolSetting("setup_completed") {
                if !store.courses(includeArchived: true).isEmpty { store.setBool("setup_completed", true) }
                else { model.go(.setup(SetupStep(rawValue: store.setting("setup_step") ?? "") ?? .welcome), replace: true) }
            }
            if let r = UserDefaults.standard.string(forKey: "route").flatMap(Route.init(path:)) { model.go(r, replace: true) }
            DebugSnapshots.runIfRequested(model: model)
            return model
        } catch {
            openError = "\(error)"
            return nil
        }
    }

    static func seedDefaults(_ store: StudyStore) {
        if store.setting("default_timezone") == nil { store.setSetting("default_timezone", TimeZone.current.identifier) }
        if store.setting("default_due_time") == nil { store.setSetting("default_due_time", "23:59") }
        if store.setting("paper_size") == nil { store.setSetting("paper_size", Locale.current.region?.identifier == "US" ? "letter" : "a4") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in sender.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) } }
        return true
    }
}

struct RootView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openSettings) var openSettings

    var body: some View {
        @Bindable var model = model
        Group {
            if case .setup(let step) = model.route {
                ZStack(alignment: .bottom) { SetupFlow(step: step); ToastHost() }
            } else {
                split
            }
        }
        .onChange(of: model.settingsRequest) { openSettings() }
        .sheet(item: $model.review) { session in ReviewView(session: session) }
        .sheet(item: $model.icsPreview) { p in ICSPreviewSheet(preview: p) }
        .sheet(isPresented: $model.showPalette) { CommandPalette() }
        .sheet(item: $model.courseEditor) { c in CourseEditor(course: c) }
        .sheet(item: Binding(get: { model.handwritingMaterialId.map { IdentifiedInt(id: $0) } }, set: { model.handwritingMaterialId = $0?.id })) { m in
            HandwritingSheet(materialId: m.id)
        }
    }

    var split: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ZStack(alignment: .bottom) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ToastHost()
            }
            .navigationTitle(model.breadcrumb.joined(separator: " › "))
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canGoBack).help("Back (⌘[)")
                    Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.canGoForward).help("Forward (⌘])")
                }
                ToolbarItem(placement: .primaryAction) { ActivityToolbarButton() }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { model.importFiles($0) }
            return true
        }
    }

    @ViewBuilder var detail: some View {
        switch model.route {
        case .inbox: InboxScreen()
        case .calendar, .occurrence: CalendarScreen()
        case .assignments, .assignment: AssignmentsScreen()
        case .course(let id, _): CourseScreen(courseId: id)
        case .study, .material, .review: StudyScreen()
        case .connections(let k): ConnectionsScreen(kind: k)
        case .today, .activity, .settings, .setup: TodayView()
        }
    }
}

struct IdentifiedInt: Identifiable { let id: Int }

func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { DispatchQueue.main.async { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

/// Three groups: Screens, Courses (archived ones collapsed) and Connections, each with a live status dot.
struct Sidebar: View {
    @Environment(AppModel.self) var model
    @AppStorage("sidebar.archivedOpen") var archivedOpen = false

    var body: some View {
        let _ = model.revision
        let inbox = model.store.inboxCount()
        let all = model.store.courses(includeArchived: true)
        let current = all.filter { !$0.archived }, archived = all.filter(\.archived)
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.sidebarSelection }, set: { if let s = $0 { model.open(s) } })) {
                Section {
                    ForEach(SidebarItem.numbered) { s in
                        Label(s.title, systemImage: s.icon)
                            .badge(s == .inbox && inbox > 0 ? inbox : 0)
                            .tag(SidebarSelection.screen(s))
                            .accessibilityLabel(s == .inbox && inbox > 0 ? "Inbox, \(inbox) items" : s.title)
                    }
                }
                Section {
                    ForEach(current) { c in courseRow(c) }
                    if !archived.isEmpty {
                        DisclosureGroup("Archived", isExpanded: $archivedOpen) {
                            ForEach(archived) { c in courseRow(c).opacity(0.55) }
                        }
                    }
                    if current.isEmpty && archived.isEmpty {
                        Button("Add a course") { model.newCourse() }.buttonStyle(.borderless).foregroundStyle(Theme.textSecondary)
                    }
                } header: {
                    HStack {
                        Text("Courses")
                        Spacer()
                        Button { model.newCourse() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add course")
                            .accessibilityLabel("Add course")
                    }
                }
                Section {
                    ForEach(ConnectionKind.allCases) { k in
                        let status = model.connectionStatus(k)
                        HStack {
                            Label(k.title, systemImage: k.icon)
                            Spacer()
                            StatusDot(status: status)
                        }
                        .tag(SidebarSelection.connection(k))
                        .accessibilityLabel("\(k.title), \(status.title)")
                    }
                } header: {
                    Button { model.go(.connections(nil)) } label: {
                        HStack(spacing: 6) {
                            Text("Connections")
                            if model.anyConnectionNeedsAttention { Circle().fill(Theme.attention).frame(width: 6, height: 6) }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            if let p = model.progress {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(p).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    func courseRow(_ c: Course) -> some View {
        HStack(spacing: 8) {
            CourseDot(color: c.color)
            Text(c.displayName).lineLimit(1)
        }
        .tag(SidebarSelection.course(c.id))
        .contextMenu {
            Button("Edit…") { model.courseEditor = c }
        }
    }
}

struct ToastHost: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let t = model.toast {
            HStack(spacing: 12) {
                if t.isError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention) }
                Text(t.message).font(.stBody).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let link = t.link {
                    Button(link.title) { model.toast = nil; model.go(link.route) }.buttonStyle(.borderless).fontWeight(.semibold)
                }
                if t.undo != nil {
                    Button("Undo") { model.performUndo() }.buttonStyle(.borderless).fontWeight(.semibold)
                }
                Button { model.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner(10)))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner(10)).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .frame(maxWidth: 640)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: Theme.motionFast), value: t.id)
        }
    }
}
