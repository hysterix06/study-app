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
                    RootView().environment(model)
                } else {
                    Text(AppDelegate.openError ?? "The database could not be opened.").padding(40)
                }
            }
            .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            if let model {
                CommandGroup(replacing: .newItem) {
                    Button("New Assignment") { model.screen = .assignments; model.focusQuickAdd += 1 }.keyboardShortcut("n")
                    Button("Import Files…") { model.chooseFilesToImport() }.keyboardShortcut("o")
                }
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo") { model.performUndo() }.keyboardShortcut("z").disabled(model.toast?.undo == nil)
                }
                CommandMenu("Go") {
                    ForEach(Array(Screen.sidebar.enumerated()), id: \.element) { i, s in
                        Button(s.title) { model.screen = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    }
                    Divider()
                    Button("Command Palette") { model.showPalette = true }.keyboardShortcut("k")
                    Button("Settings") { model.screen = .settings }.keyboardShortcut(",")
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

        MenuBarExtra {
            if let model { MenuBarView().environment(model) }
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
            // Launch arguments for demos and screenshots: -sampleData YES -screen calendar
            if UserDefaults.standard.bool(forKey: "sampleData") && !SampleData.isLoaded(store) { try? SampleData.load(store) }
            let model = AppModel(store: store)
            if let s = UserDefaults.standard.string(forKey: "screen").flatMap(Screen.init(rawValue:)) { model.screen = s }
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

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ZStack(alignment: .bottom) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ToastHost()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { model.importFiles($0) }
            return true
        }
        .sheet(item: $model.review) { session in ReviewView(session: session) }
        .sheet(item: $model.icsPreview) { p in ICSPreviewSheet(preview: p) }
        .sheet(isPresented: $model.showPalette) { CommandPalette() }
        .sheet(item: Binding(get: { model.handwritingMaterialId.map { IdentifiedInt(id: $0) } }, set: { model.handwritingMaterialId = $0?.id })) { m in
            HandwritingSheet(materialId: m.id)
        }
    }

    @ViewBuilder var detail: some View {
        switch model.screen {
        case .today: TodayView()
        case .calendar: CalendarScreen()
        case .assignments: AssignmentsScreen()
        case .courses: CoursesScreen()
        case .study: StudyScreen()
        case .inbox: InboxScreen()
        case .settings: SettingsScreen()
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

struct Sidebar: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let _ = model.revision
        let inbox = model.store.inboxCount()
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.screen }, set: { if let s = $0 { model.screen = s } })) {
                ForEach(Screen.sidebar) { s in
                    Label(s.title, systemImage: s.icon)
                        .badge(s == .inbox && inbox > 0 ? inbox : 0)
                        .tag(s)
                        .accessibilityLabel(s == .inbox && inbox > 0 ? "Inbox, \(inbox) items" : s.title)
                }
            }
            .listStyle(.sidebar)
            Divider()
            if let run = model.claudeRun {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude: \(run.label)").font(.stSmall).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }
            if let p = model.progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(p).font(.stSmall).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }
            Button { model.screen = .settings } label: {
                Label("Settings", systemImage: Screen.settings.icon).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(model.screen == .settings ? Theme.subtleFill : .clear)
        }
    }
}

struct ToastHost: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let t = model.toast {
            HStack(spacing: 12) {
                if t.isError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent) }
                Text(t.message).font(.stBody).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if t.undo != nil {
                    Button("Undo") { model.performUndo() }.buttonStyle(.borderless).fontWeight(.semibold)
                        .keyboardShortcut("z", modifiers: .command)
                }
                Button { model.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .frame(maxWidth: 640)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.15), value: t.id)
        }
    }
}
