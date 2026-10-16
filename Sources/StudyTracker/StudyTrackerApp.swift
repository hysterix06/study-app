import SwiftUI
import WebKit
import StudyCore

/// Study Tracker: this week's deadlines and classes, and each course as a book.
@main
struct StudyTrackerApp: App {
    @State private var model: AppModel

    init() {
        // `-snapshot out.png [light|dark]` draws Home from the stored data and quits (for checking the look).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count {
            Snapshot.home(to: URL(fileURLWithPath: args[i + 1]), dark: args.dropFirst(i + 2).first == "dark")
        }
        // `-snapshotBook <courseId> out.png` and `-snapshotChapter <chapterId> out.png [dark|present]`.
        if let i = args.firstIndex(of: "-snapshotBook"), i + 2 < args.count, let id = Int(args[i + 1]) {
            Snapshot.book(id, to: URL(fileURLWithPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "-snapshotChapter"), i + 2 < args.count, let id = Int(args[i + 1]) {
            Snapshot.chapter(id, to: URL(fileURLWithPath: args[i + 2]), option: args.dropFirst(i + 3).first)
        }
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Study Tracker") {
            HomeView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 780)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Sync Now") { Task { await model.sync() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.moodleSite == nil || model.syncing)
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

@MainActor
enum Snapshot {
    static func write(_ view: some View, to url: URL) -> Never {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed"); exit(1) }
        try? png.write(to: url)
        print("wrote \(url.path)")
        exit(0)
    }

    static func book(_ courseId: Int, to url: URL) -> Never {
        let model = AppModel(autoSync: false)
        write(BookContent(courseId: courseId) { _ in }.environment(model).padding(40).frame(width: 900).background(Color.white), to: url)
    }

    /// The chapter page as the app shows it: the same scheme handler, page and payload, in an offscreen window.
    static func chapter(_ id: Int, to url: URL, option: String?) -> Never {
        let model = AppModel(autoSync: false)
        guard let ch = model.store.chapter(id), let dir = BookKit.directory else { print("no chapter \(id)"); exit(1) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(BookKitSchemeHandler(root: dir), forURLScheme: "bookkit")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: option == "present" ? 760 : 1400), configuration: config)
        web.appearance = NSAppearance(named: option == "dark" ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        web.load(URLRequest(url: BookKit.pageURL))
        let payload = BookKit.payload(ch, course: model.store.course(ch.courseId))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = try? await web.callAsyncJavaScript("Book.render(payload)", arguments: ["payload": payload], contentWorld: .page)
            if option == "present" {
                _ = try? await web.evaluateJavaScript("var st = document.createElement('style'); st.textContent = '*{animation:none!important}'; document.head.appendChild(st); Book.present(); document.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowRight'})); 0")
            } else if let h = try? await web.evaluateJavaScript("document.documentElement.scrollHeight") as? NSNumber {
                // An offscreen web view paints again when its frame changes.
                web.setFrameSize(NSSize(width: 1100, height: min(CGFloat(truncating: h), 2600)))
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let image = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed"); exit(1) }
            try? png.write(to: url)
            print("wrote \(url.path)")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    static func home(to url: URL, dark: Bool) -> Never {
        let model = AppModel(autoSync: false)
        let view = HomeContent { _ in }.environment(model).padding(40).frame(width: 1100)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color.black : Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed"); exit(1) }
        try? png.write(to: url)
        print("wrote \(url.path)")
        exit(0)
    }
}
