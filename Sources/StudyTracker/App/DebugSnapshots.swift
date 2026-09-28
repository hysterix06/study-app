import AppKit
import SwiftUI

/// Development aid: `-snapshotDir /path -snapshotScreens today,calendar` renders the main window for each screen
/// to PNG files and quits. The app draws its own window, so no screen-recording permission is involved.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel) {
        guard let dir = UserDefaults.standard.string(forKey: "snapshotDir") else { return }
        let screens = (UserDefaults.standard.string(forKey: "snapshotScreens") ?? "today")
            .split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            for name in screens {
                let parts = name.split(separator: ":").map(String.init)
                if let s = Screen(rawValue: parts[0]) { model.screen = s }
                if parts.count > 1 {
                    switch parts[1] {
                    case "month": model.calendarMode = .month
                    case "agenda": model.calendarMode = .agenda
                    case "board": UserDefaults.standard.set(true, forKey: "assignments.board")
                    case "insights": UserDefaults.standard.set("insights", forKey: "study.tab")
                    case "review": model.startReview()
                    case "palette": model.showPalette = true
                    default:
                        if let tab = CourseTab(rawValue: parts[1]) { model.courseTab = tab; model.selectedCourseId = model.store.courses().max { model.store.concepts(courseId: $0.id).count < model.store.concepts(courseId: $1.id).count }?.id }
                        if let sec = SettingsSection(rawValue: parts[1]) { UserDefaults.standard.set(sec.rawValue, forKey: "settings.section") }
                        if parts[1] == "detail", let a = model.store.assignments().first { model.selectedAssignmentId = a.id }
                    }
                } else {
                    model.calendarMode = .week
                    UserDefaults.standard.set(false, forKey: "assignments.board")
                    UserDefaults.standard.set("lecture", forKey: "study.tab")
                }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.contentView != nil && w.frame.width > 400 {
                    guard let view = w.contentView?.superview ?? w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name.replacingOccurrences(of: ":", with: "-"))\(i == 0 ? "" : "-\(i)").png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                model.review = nil
                model.showPalette = false
                model.selectedAssignmentId = nil
            }
            NSApp.terminate(nil)
        }
    }
}
