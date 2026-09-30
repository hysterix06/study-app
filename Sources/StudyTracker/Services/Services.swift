import Foundation
import AppKit
import EventKit
import UserNotifications
import PDFKit
import StudyCore

// MARK: - Notifications

/// The app reaches the student instead of waiting to be opened: classes, deadlines and a morning digest.
@MainActor
final class NotificationService {
    unowned let model: AppModel
    private var pending: Task<Void, Never>?
    init(model: AppModel) { self.model = model }

    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    var enabled: Bool { model.store.boolSetting("notifications_enabled", default: false) }

    func requestPermission() async -> Bool {
        guard Self.available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func scheduleSoon() {
        guard Self.available else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await reschedule()
        }
    }

    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard enabled else { return }
        let store = model.store
        let now = Date()
        let tz = store.timezone
        var requests: [UNNotificationRequest] = []
        func add(_ id: String, _ title: String, _ body: String, at date: Date) {
            guard date > now.adding(minutes: 1) else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            let comps = calendar(in: tz).dateComponents(in: tz, from: date)
            let trig = UNCalendarNotificationTrigger(dateMatching: DateComponents(calendar: calendar(in: tz), timeZone: tz, year: comps.year,
                                                                                  month: comps.month, day: comps.day, hour: comps.hour, minute: comps.minute),
                                                     repeats: false)
            requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trig))
        }
        let lead = store.intSetting("class_notice_minutes", default: 10)
        let today = LocalDate(now, tz: tz)
        for o in store.occurrences(from: today, to: today.adding(days: 3), includeBusy: false) where o.isClass && o.status != .canceled {
            add("class-\(o.key)", o.title, [Formatters.time(o.start, tz: tz), o.location].compactMap { $0 }.joined(separator: " · "), at: o.start.adding(minutes: -lead))
        }
        let courses = store.courseMap()
        for a in store.assignments() where a.isOpen {
            guard let due = a.dueAt, due > now, due < now.adding(days: 8) else { continue }
            let course = a.courseId.flatMap { courses[$0]?.displayName } ?? ""
            add("due24-\(a.id)", "Due tomorrow: \(a.title)", "\(course) · \(Formatters.dayTime(due, tz: tz))", at: due.adding(hours: -24))
            add("due2-\(a.id)", "Due in 2 hours: \(a.title)", course, at: due.adding(hours: -2))
        }
        for b in store.studyBlocks(from: now, to: now.adding(days: 3), statuses: ["planned"]) {
            add("block-\(b.id)", "Study block: \(b.focus ?? "study")", "\(b.plannedMinutes) minutes", at: b.plannedStart.adding(minutes: -5))
        }
        // Morning digest.
        let digestTime = store.setting("digest_time").flatMap(LocalTime.init) ?? LocalTime(hour: 8, minute: 0)
        let snap = store.todaySnapshot(now: now)
        var digestDay = today
        if today.at(digestTime, tz: tz) < now { digestDay = today.adding(days: 1) }
        let dueToday = store.assignments().filter { a in a.isOpen && a.dueAt.map { LocalDate($0, tz: tz) == digestDay } == true }.count
        var body = snap.suggested.title
        if snap.cardsDue > 0 { body += " · \(snap.cardsDue) cards to review" }
        if dueToday > 0 { body += " · \(dueToday) due today" }
        add("digest-\(digestDay.string)", "Today", body, at: digestDay.at(digestTime, tz: tz))

        for r in requests.sorted(by: { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
            < ($1.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture }).prefix(60) {
            try? await center.add(r)
        }
    }
}

// MARK: - Apple Calendar and Reminders (one-way)

/// Writes classes, deadlines and planned study into a "Study Tracker" calendar (and deadlines into Reminders),
/// so they reach the student's iPhone, Watch and widgets through iCloud.
@MainActor
final class CalendarSyncService {
    unowned let model: AppModel
    let ek = EKEventStore()
    private var pending: Task<Void, Never>?
    var lastStatus: String?
    init(model: AppModel) { self.model = model }

    var calendarEnabled: Bool { model.store.boolSetting("calendar_sync_enabled") }
    var remindersEnabled: Bool { model.store.boolSetting("reminders_sync_enabled") }

    func requestCalendarAccess() async -> Bool { (try? await ek.requestFullAccessToEvents()) ?? false }
    func requestRemindersAccess() async -> Bool { (try? await ek.requestFullAccessToReminders()) ?? false }

    func syncSoon() {
        guard calendarEnabled || remindersEnabled else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            sync()
        }
    }

    private func source(for type: EKEntityType) -> EKSource? {
        let sources = ek.sources
        if let cloud = sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") }),
           !cloud.calendars(for: type).isEmpty || type == .event { return cloud }
        let defaultSource = type == .event ? ek.defaultCalendarForNewEvents?.source : ek.defaultCalendarForNewReminders()?.source
        return defaultSource ?? sources.first { $0.sourceType == .local }
    }

    private func ownCalendar(_ type: EKEntityType, settingKey: String) -> EKCalendar? {
        if let id = model.store.setting(settingKey), let cal = ek.calendar(withIdentifier: id) { return cal }
        if let existing = ek.calendars(for: type).first(where: { $0.title == "Study Tracker" && $0.allowsContentModifications }) {
            model.store.setSetting(settingKey, existing.calendarIdentifier)
            return existing
        }
        let cal = EKCalendar(for: type, eventStore: ek)
        cal.title = "Study Tracker"
        cal.cgColor = NSColor(red: 0.31, green: 0.49, blue: 0.66, alpha: 1).cgColor
        guard let src = source(for: type) else { return nil }
        cal.source = src
        do { try ek.saveCalendar(cal, commit: true) } catch { lastStatus = "Could not create the calendar: \(error.localizedDescription)"; return nil }
        model.store.setSetting(settingKey, cal.calendarIdentifier)
        return cal
    }

    func sync() {
        let store = model.store
        if calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess, let cal = ownCalendar(.event, settingKey: "ek_calendar_id") {
            let items = store.calendarExportItems()
            var map = store.syncEntries(target: "ek_event")
            var keep = Set<String>()
            for item in items {
                keep.insert(item.key)
                let fp = "\(item.title)|\(item.start.timeIntervalSince1970)|\(item.end.timeIntervalSince1970)|\(item.location ?? "")"
                if let entry = map[item.key], entry.fingerprint == fp, ek.event(withIdentifier: entry.targetId) != nil { continue }
                let ev = map[item.key].flatMap { ek.event(withIdentifier: $0.targetId) } ?? EKEvent(eventStore: ek)
                ev.calendar = cal
                ev.title = item.title; ev.startDate = item.start; ev.endDate = item.end; ev.location = item.location; ev.notes = item.notes
                ev.alarms = item.alarmMinutes.map { [EKAlarm(relativeOffset: -Double($0) * 60)] }
                do {
                    try ek.save(ev, span: .thisEvent, commit: false)
                    store.setSyncEntry(target: "ek_event", key: item.key, targetId: ev.eventIdentifier, fingerprint: fp)
                } catch { lastStatus = error.localizedDescription }
                map.removeValue(forKey: item.key)
            }
            for (key, entry) in map where !keep.contains(key) {
                if let ev = ek.event(withIdentifier: entry.targetId), ev.endDate > Date().adding(days: -1) { try? ek.remove(ev, span: .thisEvent, commit: false) }
                store.removeSyncEntry(target: "ek_event", key: key)
            }
            try? ek.commit()
            lastStatus = "Synced \(items.count) items to the Study Tracker calendar."
        }
        if remindersEnabled, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let list = ownCalendar(.reminder, settingKey: "ek_reminders_id") {
            let courses = store.courseMap()
            let tz = store.timezone
            let wanted = store.assignments(AssignmentFilter(dueFrom: Date().adding(days: -14)))
            var map = store.syncEntries(target: "ek_reminder")
            for a in wanted {
                let key = "rem:\(a.id)"
                let done = !a.isOpen
                let title = (a.courseId.flatMap { courses[$0]?.displayName }.map { "\($0): " } ?? "") + a.title
                let fp = "\(title)|\(a.dueAt?.timeIntervalSince1970 ?? 0)|\(done)"
                if let e = map[key], e.fingerprint == fp { map.removeValue(forKey: key); continue }
                let r = (map[key].flatMap { ek.calendarItem(withIdentifier: $0.targetId) as? EKReminder }) ?? EKReminder(eventStore: ek)
                r.calendar = list
                r.title = title
                if let due = a.dueAt {
                    r.dueDateComponents = calendar(in: tz).dateComponents(in: tz, from: due)
                    r.alarms = [EKAlarm(absoluteDate: due.adding(hours: -24))]
                }
                r.isCompleted = done
                do {
                    try ek.save(r, commit: false)
                    store.setSyncEntry(target: "ek_reminder", key: key, targetId: r.calendarItemIdentifier, fingerprint: fp)
                } catch { lastStatus = error.localizedDescription }
                map.removeValue(forKey: key)
            }
            try? ek.commit()
        }
    }

    func disableCalendar() {
        if let id = model.store.setting("ek_calendar_id"), let cal = ek.calendar(withIdentifier: id) { try? ek.removeCalendar(cal, commit: true) }
        model.store.setSetting("ek_calendar_id", nil)
        model.store.clearSync(target: "ek_event")
    }
}

// MARK: - Moodle

@Observable
@MainActor
final class MoodleService {
    unowned let model: AppModel
    var syncing = false
    /// The latest sync, shown as the result of connecting.
    var lastReport: MoodleSyncReport?
    init(model: AppModel) { self.model = model }

    var site: URL? { model.store.setting("moodle_url").flatMap(MoodleClient.normalizeSite) }
    var hasToken: Bool { Keychain.get(MoodleSync.tokenAccount) != nil }
    var isConnected: Bool { model.store.boolSetting("moodle_enabled") && hasToken }

    func signIn(site: String, username: String, password: String) async throws {
        guard let url = MoodleClient.normalizeSite(site) else { throw MoodleClient.MoodleError(message: "Enter your school's Moodle address.") }
        let token = try await MoodleClient.requestToken(site: url, username: username, password: password)
        useToken(site: url.absoluteString, token: token, method: "password")
    }

    /// `method` is how the student signed in ("sso", "password" or "key"), so Settings can say what happened to the password.
    func useToken(site: String, token: String, method: String = "key") {
        guard let url = MoodleClient.normalizeSite(site) else { return }
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), account: MoodleSync.tokenAccount)
        model.store.setSetting("moodle_url", url.absoluteString)
        model.store.setSetting("moodle_auth_method", method)
        model.store.setBool("moodle_needs_signin", false)
        model.store.setBool("moodle_enabled", true)
        model.refresh()
    }

    /// Name, logo and sign-in button name, kept so Settings can show the school and label the reconnect button.
    func remember(_ profile: MoodleSiteProfile) {
        model.store.setSetting("moodle_site_name", profile.name)
        model.store.setSetting("moodle_logo_url", profile.logoURL?.absoluteString)
        model.store.setSetting("moodle_provider_name", profile.providerName)
    }

    func signOut() {
        Keychain.delete(MoodleSync.tokenAccount)
        model.store.setBool("moodle_enabled", false)
        model.store.setBool("moodle_needs_signin", false)
        model.store.setSetting("moodle_user_name", nil)
        lastReport = nil
        model.refresh()
    }

    func sync(silent: Bool) async {
        guard !syncing, let site, let token = Keychain.get(MoodleSync.tokenAccount) else { return }
        syncing = true
        if !silent { model.progress = "Syncing Moodle…" }
        let store = model.store
        let files = store.boolSetting("moodle_download_files", default: true)
        let confirm = store.boolSetting("moodle_auto_confirm", default: true)
        let report = await Task.detached { await MoodleSync.run(store: store, client: MoodleClient(site: site, token: token), downloadFiles: files, autoConfirm: confirm) }.value
        lastReport = report
        syncing = false
        model.progress = nil
        model.refresh()
        if !silent || report.filesImported > 0 || report.assignmentsCreated > 0 {
            model.show("Moodle: \(report.summary)" + (report.errors.first.map { " \($0)" } ?? ""), error: !report.errors.isEmpty && report.assignmentsCreated == 0)
        }
        if report.filesImported > 0 { model.enrichPendingImages() }
    }

    var moodleCourses: [MoodleCourseInfo] {
        MoodleSync.storedCourses(store: model.store)
    }
}

// MARK: - Inbox folder watcher

/// Watches ~/StudyTracker/Inbox and hands over files once they stop growing.
final class InboxWatcher {
    let folder: URL
    let onFiles: ([URL]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var seen: [String: Int] = [:]
    private let queue = DispatchQueue(label: "study.inbox")

    init(folder: URL, onFiles: @escaping ([URL]) -> Void) { self.folder = folder; self.onFiles = onFiles }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        scheduleScan()
    }

    private func scheduleScan() { queue.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.scan() } }

    private func scan() {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var ready: [URL] = []
        var growing = false
        for u in items {
            let ext = u.pathExtension.lowercased()
            guard ext != "crdownload", ext != "download", ext != "part",
                  (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0, seen[u.path] == size { ready.append(u); seen.removeValue(forKey: u.path) }
            else { seen[u.path] = size; growing = true }
        }
        if !ready.isEmpty { DispatchQueue.main.async { self.onFiles(ready) } }
        if growing { scheduleScan() }
    }
}

// MARK: - Printing

enum PDFPrinter {
    @MainActor
    static func print(url: URL) {
        guard let doc = PDFDocument(url: url) else { NSWorkspace.shared.open(url); return }
        let info = NSPrintInfo.shared
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        if let op = doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: true) {
            op.showsPrintPanel = true
            op.run()
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
