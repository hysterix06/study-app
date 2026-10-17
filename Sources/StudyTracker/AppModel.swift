import AppKit
import Foundation
import Observation
import StudyCore

/// The app's state: what Home shows, the Moodle sync that keeps it current (at launch and every three hours while
/// the app is open), the timetable (refreshed every half hour), and the writer that turns each course into a book in
/// the background.
@Observable @MainActor
final class AppModel {
    let store: BookStore
    private(set) var courses: [Course] = []
    private(set) var hiddenCourses: [Course] = []
    private(set) var deadlines: [Deadline] = []
    private(set) var syncing = false
    /// What the sync is doing right now ("Reading course files: 3 of 40").
    private(set) var progress: String?
    private(set) var lastSync: Date?
    private(set) var lastStatus: String?
    private(set) var needsSignIn = false
    /// What the book writer is doing, and whether it's paused.
    private(set) var books = BookWriter.Status()
    /// Flashcards due now, from chapters read.
    private(set) var dueCards = 0
    /// The review sheet is open.
    var reviewing = false
    /// This week on Home: classes and deadlines day by day, and work overdue.
    private(set) var week: (overdue: [Agenda.Item], days: [Agenda.Day]) = ([], [])
    private(set) var timetableError: String?
    private(set) var mirrorError: String?
    @ObservationIgnored let calendar = CalendarAccess()
    /// The stored timetable, parsed once per download.
    @ObservationIgnored private var parsed: (stamp: String, events: [ICSEvent])?
    /// Bumped on every reload, so views that read the store directly redraw.
    private(set) var revision = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private(set) var writer: BookWriter!
    /// The Claude Code app on this Mac, if any.
    @ObservationIgnored let claudeCLI: URL? = CLIRunner.findClaude()

    static let syncInterval: TimeInterval = 3 * 3600

    /// `autoSync` off is for snapshots: the model shows what's stored and never touches the network or the AI.
    init(autoSync: Bool = true) {
        Keychain.adoptsItems = autoSync
        do { store = try BookStore.open() } catch { fatalError("Study Tracker couldn't open its database: \(error)") }
        let store = self.store, cli = claudeCLI
        writer = BookWriter(store: store, engine: { autoSync ? Self.engine(store: store, cli: cli) : nil }, onChange: { [weak self] status in
            Task { @MainActor in
                self?.books = status
                self?.reload()
            }
        })
        reload()
        guard autoSync else { return }
        Task { await writer.start() }
        if moodleSite != nil { Task { await sync() } }
        Task { await refreshTimetable() }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reload()
                await self.refreshTimetable()
                guard let last = self.lastSync, Date().timeIntervalSince(last) >= Self.syncInterval else { return }
                await self.sync()
            }
        }
        // Cards come due while the app sits in the background.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ChildProcesses.terminateAll()
        }
    }

    var moodleSite: URL? { store.setting("moodle_url").flatMap(URL.init(string:)) }
    var moodleSiteName: String? { store.setting("moodle_site_name") }
    var moodleUserName: String? { store.setting("moodle_user_name") }

    func reload() {
        courses = store.courses()
        hiddenCourses = store.courses(includeHidden: true).filter(\.hidden)
        deadlines = store.upcomingDeadlines()
        lastSync = store.setting("moodle_last_sync").flatMap { ISO.parse($0) }
        lastStatus = store.setting("moodle_last_status")
        needsSignIn = store.setting("moodle_needs_signin") == "1"
        dueCards = store.dueCount()
        timetableError = store.setting("timetable_error")
        let today = LocalDate(Date(), tz: .current)
        week = Agenda.week(classes: classes(from: today, to: today.adding(days: 6)), deadlines: deadlines, courses: courses)
        revision += 1
    }

    func course(_ id: Int) -> Course? { courses.first { $0.id == id } ?? hiddenCourses.first { $0.id == id } }

    // MARK: Moodle

    /// Saves the connection and brings everything in.
    func connect(site: URL, token: String) async {
        Keychain.set(token, account: MoodleClient.tokenAccount)
        store.setSetting("moodle_url", site.absoluteString)
        store.setSetting("moodle_needs_signin", nil)
        reload()
        await sync()
    }

    /// A token this Mac already has for the site (from an earlier version of the app), if Moodle still accepts it.
    func existingToken(for site: URL) async -> String? {
        guard Keychain.exists(MoodleClient.tokenAccount), let token = Keychain.get(MoodleClient.tokenAccount) else { return nil }
        let ok = (try? await MoodleClient(site: site, token: token).call("core_webservice_get_site_info")) != nil
        return ok ? token : nil
    }

    func sync() async {
        guard !syncing, let site = moodleSite, let token = Keychain.get(MoodleClient.tokenAccount) else { return }
        syncing = true
        progress = "Checking Moodle…"
        let store = self.store, writer = self.writer!
        let report = await MoodleSync.run(store: store, client: MoodleClient(site: site, token: token)) { [weak self] message in
            Task { @MainActor in
                guard let self, self.syncing else { return }
                self.progress = message
                self.reload()
            }
            // A syllabus just read may be enough to plan a book.
            Task { await writer.kick() }
        }
        syncing = false
        progress = nil
        reload()
        if report.needsSignIn { needsSignIn = true }
        updateMirror()
        await writer.kick()
    }

    func signOut() {
        Keychain.delete(MoodleClient.tokenAccount)
        store.setSetting("moodle_url", nil)
        reload()
    }

    func setHidden(_ course: Course, _ hidden: Bool) {
        store.setHidden(course.id, hidden)
        reload()
        if !hidden { Task { await sync() } }
    }

    // MARK: Timetable

    enum TimetableSource: String { case link, calendar }

    var timetableSource: TimetableSource? { store.setting("timetable_source").flatMap(TimetableSource.init(rawValue:)) }
    var timetableDeclined: Bool { store.setting("timetable_declined") == "1" }
    var timetableCalendars: [String] { JSON.stringArray(store.setting("timetable_calendars")) }
    var timetableLink: String? { timetableSource == .link ? Keychain.get(TimetableFeed.account) : nil }

    func classes(from: LocalDate, to: LocalDate) -> [Timetable.Instance] {
        switch timetableSource {
        case .link?:
            guard let text = store.timetableText else { return [] }
            let stamp = store.setting("timetable_fetched_at") ?? ""
            if parsed?.stamp != stamp { parsed = (stamp, (try? ICS.parse(text)) ?? []) }
            return Timetable.occurrences(parsed?.events ?? [], from: from, to: to, tz: .current)
        case .calendar?:
            let midnight = LocalTime(hour: 0, minute: 0)
            return calendar.classes(calendarIds: timetableCalendars, from: from.at(midnight, tz: .current), to: to.adding(days: 1).at(midnight, tz: .current))
        case nil:
            return []
        }
    }

    /// Checks the link and starts using it. Returns what went wrong, if anything.
    func setTimetableLink(_ link: String) async -> String? {
        guard let url = TimetableFeed.normalize(link) else { return TimetableFeed.Failure.badLink.description }
        do {
            let (text, events) = try await TimetableFeed.fetch(url)
            Keychain.set(url.absoluteString, account: TimetableFeed.account)
            store.saveTimetable(text, events: events)
            store.setSetting("timetable_source", TimetableSource.link.rawValue)
            store.setSetting("timetable_declined", nil)
            store.setSetting("timetable_error", nil)
            reload()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Downloads the timetable again when it's more than half an hour old.
    func refreshTimetable(force: Bool = false) async {
        guard timetableSource == .link, let link = Keychain.get(TimetableFeed.account), let url = TimetableFeed.normalize(link) else { return }
        if !force, let at = store.timetableFetchedAt, Date().timeIntervalSince(at) < TimetableFeed.refreshInterval { return }
        do {
            let (text, events) = try await TimetableFeed.fetch(url)
            store.saveTimetable(text, events: events)
            store.setSetting("timetable_error", nil)
        } catch {
            store.setSetting("timetable_error", Self.describe(error))
        }
        reload()
    }

    func useCalendars(_ ids: [String]) {
        store.setSetting("timetable_source", ids.isEmpty ? nil : TimetableSource.calendar.rawValue)
        store.setSetting("timetable_calendars", ids.isEmpty ? nil : JSON.string(ids))
        store.setSetting("timetable_declined", nil)
        reload()
    }

    func removeTimetable() {
        Keychain.delete(TimetableFeed.account)
        store.clearTimetable()
        for key in ["timetable_source", "timetable_calendars", "timetable_error"] { store.setSetting(key, nil) }
        reload()
    }

    func declineTimetable() {
        store.setSetting("timetable_declined", "1")
        reload()
    }

    static func describe(_ error: Error) -> String { (error as? TimetableFeed.Failure)?.description ?? error.localizedDescription }

    // MARK: Deadlines in Calendar

    var mirrorsDeadlines: Bool { store.setting("deadline_mirror") == "1" }

    func setMirror(_ on: Bool) async {
        if on {
            guard await calendar.requestAccess() else {
                mirrorError = "Study Tracker isn't allowed to use Calendar. Allow it in System Settings › Privacy & Security › Calendars."
                return
            }
            store.setSetting("deadline_mirror", "1")
            updateMirror()
        } else {
            store.setSetting("deadline_mirror", nil)
            calendar.removeMirror(store: store)
            mirrorError = nil
        }
        reload()
    }

    func updateMirror() {
        guard mirrorsDeadlines else { return }
        mirrorError = calendar.mirror(CalendarMirror.entries(deadlines: store.deadlinesToMirror(), courses: store.courses(includeHidden: true)), store: store)
    }

    // MARK: Writing books

    enum EngineChoice: String { case claudeCode = "claude-code", anthropic }

    var engineChoice: EngineChoice? { store.setting("ai_engine").flatMap(EngineChoice.init(rawValue:)) }
    var engineDeclined: Bool { store.setting("ai_declined") == "1" }
    var model: String { store.setting("ai_model") ?? defaultModel(for: engineChoice) }

    func defaultModel(for engine: EngineChoice?) -> String {
        engine == .anthropic ? AnthropicProvider.models[0].id : ClaudeCodeProvider.defaultModel
    }

    /// What writes the books, from the settings.
    nonisolated static func engine(store: BookStore, cli: URL?) -> (provider: LLMProvider, model: String)? {
        switch store.setting("ai_engine") {
        case EngineChoice.claudeCode.rawValue?:
            guard let cli else { return nil }
            let work = store.paths.root.appendingPathComponent("Claude")
            let provider = ClaudeCodeProvider(cli: cli, workingDirectory: work, timeout: 15 * 60, effort: nil) { pid, _ in ChildProcesses.add(pid) }
            return (provider, store.setting("ai_model") ?? ClaudeCodeProvider.defaultModel)
        case EngineChoice.anthropic.rawValue?:
            guard let key = Keychain.get("anthropic-key"), !key.isEmpty else { return nil }
            return (AnthropicProvider(apiKey: key), store.setting("ai_model") ?? AnthropicProvider.models[0].id)
        default:
            return nil
        }
    }

    func choose(_ engine: EngineChoice, apiKey: String? = nil) {
        if let apiKey { Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "anthropic-key") }
        store.setSetting("ai_engine", engine.rawValue)
        store.setSetting("ai_model", defaultModel(for: engine))
        store.setSetting("ai_declined", nil)
        reload()
        Task { await writer.resume() }
    }

    func setModel(_ id: String) {
        store.setSetting("ai_model", id)
        reload()
    }

    func declineBooks() {
        store.setSetting("ai_declined", "1")
        reload()
    }

    func stopWritingBooks() {
        store.setSetting("ai_engine", nil)
        reload()
        Task { await writer.stop() }
    }

    func open(_ chapter: Chapter) {
        guard !chapter.isReady else { return }
        Task { await writer.focus(on: chapter.id) }
    }

    func retry(_ job: BookJob) { Task { await writer.retry(job) } }
    func resumeBooks() { Task { await writer.resume() } }
}

/// Claude Code processes the app started, so quitting the app stops them too, including when the app is ended by a
/// signal rather than quit normally.
enum ChildProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: Set<Int32> = []
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func add(_ pid: Int32) {
        lock.withLock { _ = pids.insert(pid) }
        watchSignals
    }

    private static let watchSignals: Void = {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { terminateAll(); exit(0) }
            source.resume()
            sources.append(source)
        }
    }()

    static func terminateAll() {
        for pid in lock.withLock({ pids }) where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
    }
}
