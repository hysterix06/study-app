import SwiftUI
import AppKit
import StudyCore
import UniformTypeIdentifiers

enum Screen: String, CaseIterable, Identifiable {
    case today, calendar, assignments, courses, study, inbox, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .calendar: return "calendar"
        case .assignments: return "checklist"
        case .courses: return "books.vertical"
        case .study: return "brain.head.profile"
        case .inbox: return "tray"
        case .settings: return "gearshape"
        }
    }
    static let sidebar: [Screen] = [.today, .calendar, .assignments, .courses, .study, .inbox]
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
    var screen: Screen = .today
    var selectedCourseId: Int?
    var selectedAssignmentId: Int?
    var studyMaterialId: Int?
    var courseTab: CourseTab = .overview
    var showPalette = false
    var focusQuickAdd = 0
    var toast: Toast?
    var review: ReviewSession?
    var progress: String?
    var calendarDate = LocalDate.today()
    var calendarMode: CalendarMode = .week
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

    func open(_ s: Screen) { screen = s }
    func openCourse(_ id: Int, tab: CourseTab = .overview) { selectedCourseId = id; courseTab = tab; screen = .courses }
    func openAssignment(_ id: Int) { selectedAssignmentId = id; screen = .assignments }
    func openStudy(_ materialId: Int?) { studyMaterialId = materialId; screen = .study }

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
            calendarMode = .week
            calendarDate = LocalDate.today(tz: tz)
            screen = .calendar
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

enum CalendarMode: String, CaseIterable, Identifiable { case week, month, agenda; var id: String { rawValue }; var title: String { rawValue.capitalized } }
enum CourseTab: String, CaseIterable, Identifiable {
    case overview, materials, concepts, notes, cards
    var id: String { rawValue }
    var title: String { self == .notes ? "Sheets & notes" : rawValue.capitalized }
}
