import SwiftUI
import AppKit
import StudyCore
import UniformTypeIdentifiers

/// Items in the sidebar. Each one opens the last route used under it.
enum SidebarItem: String, CaseIterable, Identifiable {
    case today, inbox, calendar, assignments, study, courses
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .inbox: return "tray"
        case .calendar: return "calendar"
        case .assignments: return "checklist"
        case .study: return "brain.head.profile"
        case .courses: return "books.vertical"
        }
    }
    /// ⌘1…⌘5, in sidebar order.
    static let numbered: [SidebarItem] = [.today, .inbox, .calendar, .assignments, .study]
    static let sidebar: [SidebarItem] = numbered + [.courses]
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var undo: UndoSnapshot?
    var isError = false
}

@MainActor
@Observable
final class AppModel {
    let store: StudyStore
    var revision = 0
    /// Where the main window is. The only way to change it is `go(_:)`.
    private(set) var route: Route = .today
    private(set) var backStack: [Route] = []
    private(set) var forwardStack: [Route] = []
    /// Returning to a sidebar item restores the route last used under it.
    private var lastRoute: [Route.ScreenKey: Route] = [:]
    private var lastCourseId: Int?
    var showPalette = false
    var focusQuickAdd = 0
    var toast: Toast?
    var review: ReviewSession?
    var progress: String?
    var icsPreview: ICSPreview?
    var handwritingMaterialId: Int?
    var claudeRun: ClaudeRunState?

    let claude = ClaudeService()
    var notifications: NotificationService!
    var calendarSync: CalendarSyncService!
    var moodle: MoodleService!
    private var watcher: InboxWatcher?
    private var lastDataVersion = 0
    private var timers: [Timer] = []
    private var toastTask: Task<Void, Never>?
    private let worker = DispatchQueue(label: "study.worker", qos: .userInitiated)

    init(store: StudyStore) {
        self.store = store
        notifications = NotificationService(model: self)
        calendarSync = CalendarSyncService(model: self)
        moodle = MoodleService(model: self)
        lastDataVersion = store.db.dataVersion
        store.backupIfOlderThan(hours: 20, reason: "daily")
        watcher = InboxWatcher(folder: store.paths.inbox) { [weak self] urls in
            Task { @MainActor in self?.importFiles(urls, fromInboxFolder: true) }
        }
        watcher?.start()
        // Notice writes from Claude (another SQLite connection) and refresh.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkExternalChanges() }
        })
        // Periodic housekeeping: backups, feeds, Moodle, notifications, calendar sync.
        timers.append(Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.housekeeping() }
        })
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            housekeeping()
            enrichPendingImages()
        }
    }

    var tz: TimeZone { store.timezone }

    func refresh() {
        revision += 1
        lastDataVersion = store.db.dataVersion
        notifications.scheduleSoon()
        calendarSync.syncSoon()
    }

    private func checkExternalChanges() {
        let v = store.db.dataVersion
        if v != lastDataVersion {
            lastDataVersion = v
            revision += 1
            notifications.scheduleSoon()
            calendarSync.syncSoon()
        }
    }

    func housekeeping() {
        store.backupIfOlderThan(hours: 20, reason: "daily")
        Task { await syncFeeds(silent: true) }
        if store.boolSetting("moodle_enabled"), let last = store.setting("moodle_last_sync").flatMap({ ISO.parse($0) }) {
            if Date().timeIntervalSince(last) > 3 * 3600 { Task { await moodle.sync(silent: true) } }
        } else if store.boolSetting("moodle_enabled") {
            Task { await moodle.sync(silent: true) }
        }
        notifications.scheduleSoon()
        calendarSync.syncSoon()
    }

    // MARK: Toasts and undo (8 seconds, §5.2)

    func show(_ message: String, undo: UndoSnapshot? = nil, error: Bool = false) {
        toast = Toast(message: message, undo: undo, isError: error)
        toastTask?.cancel()
        let id = toast!.id
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if toast?.id == id { toast = nil }
        }
    }

    func performUndo() {
        guard let snap = toast?.undo else { return }
        do { try store.undo(snap); toast = Toast(message: "Undone."); refresh() }
        catch { show("Could not undo: \(error)", error: true) }
    }

    func fail(_ error: Error) { show("\(error)", error: true) }

    func run(_ label: String? = nil, _ body: () throws -> UndoSnapshot?) {
        do {
            let snap = try body()
            refresh()
            if let label { show(label, undo: snap) }
        } catch { fail(error) }
    }

    // MARK: Navigation

    /// Navigates by route. `replace` changes the current entry without adding history (tabs, date steps, filters).
    func go(_ r: Route, replace: Bool = false) {
        switch r {
        case .review(let courseId):
            startReview(courseId: courseId); return
        case .activity:
            go(.connections(.claude), replace: replace); return
        case .setup:
            go(.today, replace: replace); return
        default: break
        }
        guard r != route else { return }
        if !replace {
            backStack.append(route)
            if backStack.count > 50 { backStack.removeFirst(backStack.count - 50) }
            forwardStack.removeAll()
        }
        setRoute(r)
    }

    func go(path: String) { if let r = Route(path: path) { go(r) } }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let r = backStack.popLast() else { return }
        forwardStack.append(route)
        setRoute(r)
    }

    func goForward() {
        guard let r = forwardStack.popLast() else { return }
        backStack.append(route)
        setRoute(r)
    }

    private func setRoute(_ r: Route) {
        route = r
        lastRoute[r.screen] = r
        if case .course(let id, _) = r { lastCourseId = id }
    }

    /// Opens a sidebar item at its last route.
    func open(_ item: SidebarItem) {
        switch item {
        case .today: go(.today)
        case .inbox: go(lastRoute[.inbox] ?? .inbox(nil))
        case .calendar: go(lastRoute[.calendar] ?? .calendar(.week, nil))
        case .assignments: go(lastRoute[.assignments] ?? .assignments)
        case .study: go(lastRoute[.study] ?? .study(.lectures))
        case .courses:
            let courses = store.courses()
            let id = lastCourseId.flatMap { id in courses.contains { $0.id == id } ? id : nil } ?? courses.first?.id
            if let id { go(lastRoute[.course(id)] ?? .course(id, .overview)) } else { go(.course(0, .overview)) }
        }
    }

    var sidebarItem: SidebarItem? {
        switch route.screen {
        case .today: return .today
        case .inbox: return .inbox
        case .calendar: return .calendar
        case .assignments: return .assignments
        case .study: return .study
        case .course: return .courses
        case .connections, .settings, .setup: return nil
        }
    }

    func openCourse(_ id: Int, tab: CourseTab = .overview) { go(.course(id, tab)) }
    func openAssignment(_ id: Int) { go(.assignment(id)) }
    func openMaterial(_ id: Int) { go(.material(id)) }

    /// The course shown on the course screen; selecting another course is a new history entry.
    var selectedCourseId: Int? {
        get { if case .course(let id, _) = route, id != 0 { return id }; return lastCourseId }
        set { go(.course(newValue ?? 0, newValue == nil ? .overview : courseTab)) }
    }

    var courseTab: CourseTab {
        get { if case .course(_, let tab) = route { return tab }; return .overview }
        set { if case .course(let id, _) = route { go(.course(id, newValue), replace: true) } }
    }

    var selectedAssignmentId: Int? {
        get { if case .assignment(let id) = route { return id }; return nil }
        set { if let newValue { go(.assignment(newValue)) } else { go(.assignments, replace: true) } }
    }

    var studyMaterialId: Int? {
        get { if case .material(let id) = route { return id }; return nil }
        set { go(newValue.map { .material($0) } ?? .study(.lectures), replace: true) }
    }

    var calendarMode: CalendarMode {
        get { if case .calendar(let m, _) = route { return m }; return .week }
        set { go(.calendar(newValue, calendarDate), replace: true) }
    }

    var calendarDate: LocalDate {
        get {
            switch route {
            case .calendar(_, let d): return d ?? LocalDate.today(tz: tz)
            case .occurrence(let key): return occurrenceDate(key) ?? LocalDate.today(tz: tz)
            default: return LocalDate.today(tz: tz)
            }
        }
        set { go(.calendar(calendarMode, newValue), replace: true) }
    }

    /// The local date of an occurrence key: `p12:2026-09-30`, `e5` or `b7`.
    func occurrenceDate(_ key: String) -> LocalDate? {
        if key.hasPrefix("p"), let d = key.split(separator: ":").last.flatMap({ LocalDate(String($0)) }) { return d }
        guard let id = Int(key.dropFirst()) else { return nil }
        if key.hasPrefix("e"), let e = store.events().first(where: { $0.id == id }) { return LocalDate(e.start, tz: tz) }
        if key.hasPrefix("b"), let b = store.studyBlocks(statuses: ["proposed", "planned", "done", "dismissed"]).first(where: { $0.id == id }) {
            return LocalDate(b.plannedStart, tz: tz)
        }
        return nil
    }

    /// The toolbar path, e.g. Courses › HM210 › Materials.
    var breadcrumb: [String] {
        switch route {
        case .today: return ["Today"]
        case .inbox(let s): return ["Inbox"] + (s.map { [$0.rawValue.capitalized] } ?? [])
        case .calendar(let m, _): return ["Calendar", m.title]
        case .occurrence: return ["Calendar", "Week"]
        case .assignments: return ["Assignments"]
        case .assignment(let id): return ["Assignments", store.assignment(id)?.title ?? "Assignment"]
        case .course(let id, let tab):
            guard let c = store.course(id) else { return ["Courses"] }
            return ["Courses", c.displayName, tab.title]
        case .material(let id): return ["Study", store.material(id)?.title ?? "Material"]
        case .study(let s): return ["Study", s.title]
        case .connections(let k): return ["Connections"] + (k.map { [$0.title] } ?? [])
        case .settings(let s): return ["Settings", s.title]
        case .review, .activity, .setup: return []
        }
    }

    // MARK: Import

    func importFiles(_ urls: [URL], fromInboxFolder: Bool = false, courseId: Int? = nil) {
        let files = urls.filter { u in
            let ext = u.pathExtension.lowercased()
            return ext == "ics" || MaterialParser.supportedExtensions.contains(ext)
        }
        let ics = files.filter { $0.pathExtension.lowercased() == "ics" }
        let materials = files.filter { $0.pathExtension.lowercased() != "ics" }
        if let first = ics.first { previewICS(fileURL: first) }
        guard !materials.isEmpty else { return }
        progress = "Reading \(materials.count == 1 ? materials[0].lastPathComponent : "\(materials.count) files")…"
        let store = self.store
        worker.async {
            var results: [ImportOutcome] = []
            for u in materials {
                let access = u.startAccessingSecurityScopedResource()
                results.append(store.importMaterial(from: u, courseId: courseId, removeOriginal: fromInboxFolder))
                if access { u.stopAccessingSecurityScopedResource() }
            }
            DispatchQueue.main.async {
                self.progress = nil
                self.refresh()
                let imported = results.compactMap { if case .imported(_, let t) = $0 { return t }; return nil }
                let dups = results.compactMap { if case .duplicate(_, let t) = $0 { return t }; return nil }
                let failed = results.compactMap { if case .failed(let m) = $0 { return m }; return nil }
                var parts: [String] = []
                if imported.count == 1 { parts.append("\(imported[0]) is in the Inbox.") } else if imported.count > 1 { parts.append("\(imported.count) files are in the Inbox.") }
                if !dups.isEmpty { parts.append("\(dups.count == 1 ? "\"\(dups[0])\" is" : "\(dups.count) files are") already in your library.") }
                if !failed.isEmpty { parts.append(failed.count == 1 ? failed[0] : "\(failed.count) files could not be read.") }
                self.show(parts.joined(separator: " "), error: imported.isEmpty && !failed.isEmpty)
                self.enrichPendingImages()
                if self.store.boolSetting("auto_process") { self.autoProcessReady() }
            }
        }
    }

    /// OCR of pictures inside slides runs in the background after import so the import itself stays fast.
    func enrichPendingImages() {
        let store = self.store
        worker.async {
            let ids = store.materialsNeedingImageText()
            var n = 0
            for id in ids { n += store.enrichImageText(materialId: id) }
            if n > 0 { DispatchQueue.main.async { self.refresh() } }
        }
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["pptx", "pdf", "docx", "md", "txt", "png", "jpg", "jpeg", "heic", "ics"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose lecture slides, PDFs, Word files or a calendar (.ics)"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    // MARK: Calendar import

    func previewICS(fileURL: URL, role: String = "school") {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let plan = try store.planICSImport(text: text, role: role, sourceId: nil)
            icsPreview = ICSPreview(name: fileURL.lastPathComponent, text: text, role: role, plan: plan, sourceId: nil)
        } catch { fail(error) }
    }

    func applyICS(_ p: ICSPreview) {
        do {
            var sourceId = p.sourceId
            if sourceId == nil {
                sourceId = try store.addCalendarSource(name: p.name, kind: "file", role: p.role, feedURL: nil)
                // Re-plan against the new source so stale detection works on the next import.
                let plan = try store.planICSImport(text: p.text, role: p.role, sourceId: sourceId)
                try store.applyICSImport(plan, sourceId: sourceId)
            } else {
                try store.applyICSImport(p.plan, sourceId: sourceId)
            }
            store.setSourceStatus(sourceId!, p.plan.summary)
            icsPreview = nil
            refresh()
            show("Calendar imported: \(p.plan.summary).")
        } catch { fail(error) }
    }

    func syncFeeds(silent: Bool) async {
        for s in store.calendarSources() where s.kind == "feed" {
            do {
                let text = try await store.fetchFeed(s)
                let plan = try store.planICSImport(text: text, role: s.role, sourceId: s.id)
                if plan.isEmpty { store.setSourceStatus(s.id, "Up to date"); continue }
                try store.applyICSImport(plan, sourceId: s.id)
                store.setSourceStatus(s.id, plan.summary)
                if !silent { show("\(s.name): \(plan.summary).") }
            } catch {
                store.setSourceStatus(s.id, "Failed: \(error)")
                if !silent { fail(error) }
            }
        }
        refresh()
    }

    // MARK: Schedule edits

    func applyScheduleEdit(_ occ: Occurrence, scope: EditScope, change: ScheduleChange) {
        let plan = EditPlanner.plan(occurrence: occ, scope: scope, change: change, patterns: store.patterns(),
                                    exceptions: store.exceptions(), events: store.events())
        guard !plan.mutations.isEmpty else { return }
        do {
            let snap = try store.apply(plan, label: "Edited \(occ.title)")
            refresh()
            let base = change.cancel ? "Canceled \(occ.title)" : "Updated \(occ.title)"
            show(([base + "."] + plan.warnings).joined(separator: " "), undo: snap)
        } catch { fail(error) }
    }

    // MARK: Planner

    func planStudy(focusAssignment: Int? = nil) {
        let now = Date()
        let busy = store.busyIntervals(from: now, to: now.adding(days: 22))
        let existing = store.studyBlocks(from: now.adding(days: -1), to: now.adding(days: 30), statuses: ["planned", "done", "proposed"])
            .filter { $0.createdBy != "planner" || $0.status != "proposed" }
        var result = StudyPlanner.plan(assignments: store.assignments(), busy: busy, existing: existing, settings: store.plannerSettings, now: now, tz: tz)
        if let focusAssignment { result.blocks = result.blocks.filter { $0.assignmentId == focusAssignment } + result.blocks.filter { $0.assignmentId != focusAssignment } }
        do {
            try store.replacePlannerProposals(result.blocks)
            refresh()
            go(.calendar(.week, LocalDate.today(tz: tz)))
            let msg = result.blocks.isEmpty ? "Nothing needs planning in the next three weeks." : "Proposed \(result.blocks.count) study block\(result.blocks.count == 1 ? "" : "s"). Accept the ones that work."
            show(([msg] + result.warnings).joined(separator: " "))
        } catch { fail(error) }
    }

    // MARK: Claude

    func copyPrompt(_ name: String, _ args: [String: String]) {
        do {
            let text = try Prompts.render(name, args: args, store: store)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            show("Prompt copied. Paste it into Claude Desktop.")
        } catch { fail(error) }
    }

    func openClaude() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Runs a prompt with Claude Code in the background (uses the student's own Claude plan), if installed.
    func runWithClaude(_ name: String, _ args: [String: String], label: String) {
        guard claudeRun == nil else { show("Claude is still working on \(claudeRun!.label).", error: true); return }
        guard let cli = claude.findCLI() else { copyPrompt(name, args); return }
        guard let prompt = try? Prompts.render(name, args: args, store: store) else { return }
        claudeRun = ClaudeRunState(label: label, started: Date())
        Task {
            let outcome = await claude.runHeadless(cli: cli, prompt: prompt, store: store)
            claudeRun = nil
            refresh()
            switch outcome {
            case .success(let summary): show("Claude finished \(label). " + summary.prefix(160))
            case .failure(let e): show("Claude could not finish \(label): \(e.localizedDescription). The prompt is copied instead.", error: true); copyPrompt(name, args)
            }
        }
    }

    func process(materialId: Int) {
        let title = store.material(materialId)?.title ?? "the lecture"
        if claude.findCLI() != nil && store.boolSetting("use_claude_code", default: true) {
            runWithClaude("process_lecture", ["material_id": "\(materialId)"], label: "processing \(title)")
        } else {
            copyPrompt("process_lecture", ["material_id": "\(materialId)"])
        }
    }

    func autoProcessReady() {
        guard claude.findCLI() != nil, claudeRun == nil,
              let m = store.unprocessedMaterials().first(where: { $0.role == .lecture }) else { return }
        process(materialId: m.id)
    }

    // MARK: Review

    func startReview(courseId: Int? = nil) {
        let cards = store.reviewQueue(courseId: courseId, limit: 20)
        guard !cards.isEmpty else { show("No cards are due. Nice."); return }
        review = ReviewSession(cards: cards, courseId: courseId, sessionId: try? store.startSession(kind: "review", courseId: courseId, materialId: nil))
    }

    // MARK: Cornell sheet

    func exportSheet(_ note: Note, print: Bool) {
        guard let sheet = CornellSheet.decode(note.dataJson) else { return }
        let paper = PaperSize(rawValue: store.setting("paper_size") ?? "a4") ?? .a4
        let data = CornellRenderer.pdf(sheet, paper: paper)
        let name = Slug.make("\(sheet.courseCode) \(sheet.materialTitle) - Cornell") + ".pdf"
        let url = store.paths.export.appendingPathComponent(name)
        do {
            try data.write(to: url)
            if let vault = store.setting("obsidian_vault_path"), !vault.isEmpty {
                let dir = URL(fileURLWithPath: vault).appendingPathComponent("Study Tracker/\(Slug.make(sheet.courseCode))")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? sheet.obsidianMarkdown.write(to: dir.appendingPathComponent(Slug.make(sheet.title) + ".md"), atomically: true, encoding: .utf8)
            }
            if print { PDFPrinter.print(url: url) } else { NSWorkspace.shared.open(url) }
        } catch { fail(error) }
    }
}

struct ClaudeRunState { var label: String; var started: Date }

struct ICSPreview: Identifiable {
    let id = UUID()
    var name: String
    var text: String
    var role: String
    var plan: ICSImportPlan
    var sourceId: Int?
}

