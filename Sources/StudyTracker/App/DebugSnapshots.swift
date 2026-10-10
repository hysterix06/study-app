import AppKit
import SwiftUI
import WebKit
import StudyCore

/// Development aid: `-snapshotDir /path -snapshotRoutes today,calendar/month,course/*/concepts` renders the main
/// window at each route to PNG files and quits. `*` picks a sample object (the course with the most concepts, the
/// first assignment, the first lecture). `palette`, `review` and `assignments/board` open those overlays.
/// `notebook/12` renders topic 12's notebook page by itself at full height, however tall it is.
/// The app draws its own window, so no screen-recording permission is involved.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel) {
        guard let dir = UserDefaults.standard.string(forKey: "snapshotDir") else { return }
        let list = UserDefaults.standard.string(forKey: "snapshotRoutes") ?? UserDefaults.standard.string(forKey: "snapshotScreens") ?? "today"
        let entries = list.split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            for entry in entries {
                if entry.hasPrefix("notebook/"), let id = Int(entry.dropFirst("notebook/".count)), let t = model.store.topic(id) {
                    let page = NotebookPageView(topic: t, number: model.store.topicNumbers(courseId: t.courseId)[id] ?? "",
                                                guide: model.store.notebook(topicId: id))
                    await renderAlone(page, to: URL(fileURLWithPath: dir).appendingPathComponent("notebook-\(id).png"))
                    continue
                }
                UserDefaults.standard.set(false, forKey: "assignments.board")
                switch entry {
                case "palette": model.showPalette = true
                case "review": model.startReview()
                case "needs-a-look": model.go(.needsLook)
                case "assignments/board":
                    UserDefaults.standard.set(true, forKey: "assignments.board")
                    model.go(.assignments)
                case let e where e.hasPrefix("session/"):
                    openSession(e, model: model)
                default:
                    if let r = Route(path: resolve(entry, model: model)) { model.go(r) }
                }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                let name = entry.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "*", with: "x")
                for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.contentView != nil && w.frame.width > 400 {
                    guard let view = w.contentView?.superview ?? w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    await drawWebViews(in: view, onto: rep)
                    let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(i == 0 ? "" : "-\(i)").png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                model.showPalette = false
                model.session = nil
            }
            NSApp.terminate(nil)
        }
    }

    /// One view on its own, as tall as it needs to be, in the app's theme and appearance.
    private static func renderAlone<V: View>(_ view: V, to file: URL, width: CGFloat = 760) async {
        let host = NSHostingView(rootView: view.padding(20).frame(width: width).themed().canvasBackground())
        host.appearance = NSApp.effectiveAppearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    /// Web views draw in another process, so the window capture shows them blank: each one is asked for its own
    /// picture, which is drawn into the capture where it sits.
    private static func drawWebViews(in root: NSView, onto rep: NSBitmapImageRep) async {
        var webs: [WKWebView] = []
        func collect(_ v: NSView) { if let w = v as? WKWebView { webs.append(w) } else { v.subviews.forEach(collect) } }
        collect(root)
        guard !webs.isEmpty, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        for web in webs where !web.isHiddenOrHasHiddenAncestor {
            let visible = web.visibleRect
            guard visible.width > 1, visible.height > 1 else { continue }
            let config = WKSnapshotConfiguration()
            config.rect = visible
            guard let image = try? await web.takeSnapshot(configuration: config) else { continue }
            var frame = web.convert(visible, to: root)
            if !root.isFlipped { /* already bottom-left */ } else { frame.origin.y = root.bounds.height - frame.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            image.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// `session/topic@practice`: opens a session of that kind on the course with the most topics, at that step.
    private static func openSession(_ entry: String, model: AppModel) {
        let store = model.store
        let parts = entry.dropFirst("session/".count).split(separator: "@").map(String.init)
        guard let course = store.courses().max(by: { store.topics(courseId: $0.id).count < store.topics(courseId: $1.id).count }) else { return }
        let topics = store.topics(courseId: course.id)
        let pick: SessionPick
        switch parts.first ?? "" {
        case "notebook": pick = SessionPick(kind: .notebook, courseId: course.id, topicIds: topics.filter { !$0.inNotebook }.map(\.id), minutes: 25, score: 1)
        case "review": pick = SessionPick(kind: .review, courseId: nil, minutes: 25, score: 1)
        case "exam":
            let exam = store.assignments(AssignmentFilter(courseId: course.id)).first { $0.kind == .exam }
            pick = SessionPick(kind: .examPrep, courseId: course.id, assignmentId: exam?.id,
                               topicIds: exam.map { store.assessmentTopicIds(assignmentId: $0.id) } ?? topics.map(\.id), minutes: 25, score: 1)
        default:
            let t = topics.first { store.lesson(topicId: $0.id) != nil && !store.practiceItems(topicId: $0.id).isEmpty } ?? topics.first
            pick = SessionPick(kind: .topic, courseId: course.id, topicId: t?.id, minutes: 25, score: 1)
        }
        model.startSession(pick)
        guard let target = parts.dropFirst().first.flatMap(SessionStep.init), let c = model.session else { return }
        if target == .done { c.finish(); return }
        for _ in 0..<8 where c.step != target && c.step != .done { c.next() }
    }

    /// Replaces `*` with a sample id for the object kind in front of it.
    private static func resolve(_ entry: String, model: AppModel) -> String {
        guard entry.contains("*") else { return entry }
        let store = model.store
        let id: Int?
        if entry.hasPrefix("course/") {
            id = store.courses().max { store.topics(courseId: $0.id).count < store.topics(courseId: $1.id).count }?.id
        } else if entry.hasPrefix("topic/") {
            id = store.courses().flatMap { store.topics(courseId: $0.id) }.first { store.lesson(topicId: $0.id) != nil }?.id
        } else if entry.hasPrefix("assignment/") {
            id = store.assignments().first?.id
        } else if entry.hasPrefix("material/") {
            id = store.materials().first { $0.courseId != nil && $0.role == .lecture }?.id ?? store.materials().first?.id
        } else { id = nil }
        return entry.replacingOccurrences(of: "*", with: id.map(String.init) ?? "0")
    }
}
