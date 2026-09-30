import AppKit
import SwiftUI
import StudyCore

/// Development aid: `-snapshotDir /path -snapshotRoutes today,calendar/month,course/*/concepts` renders the main
/// window at each route to PNG files and quits. `*` picks a sample object (the course with the most concepts, the
/// first assignment, the first lecture). `palette`, `review` and `assignments/board` open those overlays.
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
                UserDefaults.standard.set(false, forKey: "assignments.board")
                switch entry {
                case "palette": model.showPalette = true
                case "review": model.startReview()
                case "assignments/board":
                    UserDefaults.standard.set(true, forKey: "assignments.board")
                    model.go(.assignments)
                default:
                    if let r = Route(path: resolve(entry, model: model)) { model.go(r) }
                }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                let name = entry.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "*", with: "x")
                for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.contentView != nil && w.frame.width > 400 {
                    guard let view = w.contentView?.superview ?? w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(i == 0 ? "" : "-\(i)").png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                model.review = nil
                model.showPalette = false
            }
            NSApp.terminate(nil)
        }
    }

    /// Replaces `*` with a sample id for the object kind in front of it.
    private static func resolve(_ entry: String, model: AppModel) -> String {
        guard entry.contains("*") else { return entry }
        let store = model.store
        let id: Int?
        if entry.hasPrefix("course/") {
            id = store.courses().max { store.concepts(courseId: $0.id).count < store.concepts(courseId: $1.id).count }?.id
        } else if entry.hasPrefix("assignment/") {
            id = store.assignments().first?.id
        } else if entry.hasPrefix("material/") {
            id = store.materials().first { $0.courseId != nil && $0.role == .lecture }?.id ?? store.materials().first?.id
        } else { id = nil }
        return entry.replacingOccurrences(of: "*", with: id.map(String.init) ?? "0")
    }
}
