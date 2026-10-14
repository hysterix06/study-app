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
                    Button("Home") { model.open(.home) }.keyboardShortcut("1")
                    Button("Schedule") { model.open(.schedule) }.keyboardShortcut("2")
                    ForEach(Array(model.store.courses().prefix(7).enumerated()), id: \.element.id) { i, c in
                        Button(c.displayName) { model.open(.course(c.id)) }.keyboardShortcut(KeyEquivalent(Character("\(i + 3)")))
                    }
                    Divider()
                    Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.canGoBack)
                    Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!model.canGoForward)
                    Divider()
                    Button("Command Palette") { model.showPalette = true }.keyboardShortcut("k")
                    Button("Needs a Look") { model.go(.needsLook) }
                }
                CommandMenu("Study") {
                    Button("Start Next Session") {
                        if let p = model.store.nextSessionPlan().primary { model.startSession(p) } else { model.show("You're up to date.") }
                    }.keyboardShortcut(.return, modifiers: [.command])
                    Button("Just Review") { model.startReview() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("Plan Study Blocks") { model.planStudy() }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Sync Calendars and Moodle") {
                        Task { await model.syncFeeds(silent: false); await model.moodle.sync(silent: false) }
                    }.keyboardShortcut("s", modifiers: [.command, .shift])
                    Divider()
                    Button("New AI Chat") { model.newChat() }.keyboardShortcut("l", modifiers: [.command, .shift])
                }
            }
        }

        Settings {
            if let model { SettingsWindow().environment(model).canvasBackground().themed() }
        }

        Window("AI Activity", id: AIActivityWindow.id) {
            if let model { AIActivityWindow().environment(model).canvasBackground().themed() }
        }
        .defaultSize(width: 720, height: 760)
        .keyboardShortcut("a", modifiers: [.command, .shift])

        MenuBarExtra {
            if let model { MenuBarView().environment(model).canvasBackground().themed() }
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
        Keychain.adoptsItems = true
        do {
            let store = try StudyStore.open()
            seedDefaults(store)
            // Launch arguments for demos and screenshots: -sampleData YES -route calendar/month
            if UserDefaults.standard.bool(forKey: "sampleData") && !SampleData.isLoaded(store) { try? SampleData.load(store) }
            let model = AppModel(store: store)
            // First launch opens setup; people who already have courses skip it.
            if !store.boolSetting("setup_completed") {
                if !store.courses(includeArchived: true).isEmpty { store.setBool("setup_completed", true) }
                else { model.go(.setup(SetupStep(name: store.setting("setup_step") ?? "") ?? .welcome), replace: true) }
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ThemeStore.shared.applyAppearance()
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
            } else if let session = model.session {
                ZStack(alignment: .bottom) { SessionView(c: session).id(session.id); ToastHost() }
            } else {
                split
            }
        }
        .onChange(of: model.settingsRequest) { openSettings() }
        .sheet(item: $model.icsPreview) { p in ICSPreviewSheet(preview: p).themedSheet() }
        .sheet(isPresented: $model.showPalette) { CommandPalette().themedSheet() }
        .sheet(item: $model.courseEditor) { c in CourseEditor(course: c).themedSheet() }
        .sheet(item: $model.chat) { c in ChatPanel(chat: c).themedSheet() }
        .sheet(item: $model.paste) { r in PasteSheet(request: r).themedSheet() }
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
            .canvasBackground()
            .navigationTitle(model.breadcrumb.joined(separator: " › "))
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canGoBack).help("Back (⌘[)")
                    Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.canGoForward).help("Forward (⌘])")
                }
                ToolbarItem(placement: .primaryAction) { AIStatusLine() }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings (⌘,)").accessibilityLabel("Settings")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { model.importFiles($0) }
            return true
        }
    }

    @ViewBuilder var detail: some View {
        switch model.route {
        case .home, .setup, .settings: HomeView()
        case .needsLook: NeedsLookScreen()
        case .calendar, .occurrence: CalendarScreen()
        case .assignments, .assignment: AssignmentsScreen()
        case .course(let id, _): CourseScreen(courseId: id)
        case .topic(let id): TopicPage(topicId: id)
        case .material(let id): MaterialPage(materialId: id)
        }
    }
}

/// The quiet line in the toolbar: what the AI is doing now. It opens the AI Activity window.
struct AIStatusLine: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    var body: some View {
        let _ = model.revision
        let failed = model.store.jobsNeedingAttention().filter { $0.state == .failed && !$0.isQuiet }.count
        Button { openWindow(id: AIActivityWindow.id) } label: {
            HStack(spacing: 6) {
                if model.jobs.isRunning { ProgressView().controlSize(.mini) }
                if let line = model.jobs.statusLine { Text(line).font(.stSmall).lineLimit(1).frame(maxWidth: 260) }
                else if failed > 0 { Label("\(failed) AI task\(failed == 1 ? "" : "s") failed", systemImage: "exclamationmark.triangle").font(.stSmall) }
                else { Image(systemName: "sparkles") }
            }.foregroundStyle(failed > 0 && model.jobs.statusLine == nil ? Theme.attention : Theme.textSecondary)
        }
        .buttonStyle(.borderless)
        .help("AI activity: what the AI is doing, with pause and cancel (⇧⌘A)")
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

/// Home, one row per course (archived ones collapsed), and Schedule; Settings at the bottom.
struct Sidebar: View {
    @Environment(AppModel.self) var model
    @AppStorage("sidebar.archivedOpen") var archivedOpen = false

    var body: some View {
        let _ = model.revision
        let looks = model.store.needsLookCount()
        let all = model.store.courses(includeArchived: true)
        let current = all.filter { !$0.archived }, archived = all.filter(\.archived)
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.sidebarSelection }, set: { if let s = $0 { model.open(s) } })) {
                Section {
                    Label("Home", systemImage: "house").badge(looks).tag(SidebarSelection.home)
                        .accessibilityLabel(looks > 0 ? "Home, \(looks) things need a look" : "Home")
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
                    Label("Schedule", systemImage: "calendar").tag(SidebarSelection.schedule)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(ThemeStore.shared.spec.systemSidebar ? .automatic : .hidden)
            if let p = model.progress {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(p).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }
            Divider()
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.textSecondary).help("Settings (⌘,)")
                if model.anyConnectionNeedsAttention {
                    Button { model.go(.settings(.connections)) } label: { Circle().fill(Theme.attention).frame(width: 7, height: 7) }
                        .buttonStyle(.borderless).help("A connection needs attention")
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .background(Theme.sidebar)
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
