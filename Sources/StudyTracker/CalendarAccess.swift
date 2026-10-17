import EventKit
import Foundation
import StudyCore

/// Apple Calendar, for two optional jobs: reading the timetable from calendars on this Mac (when the school won't let
/// Outlook publish a link), and copying deadlines into a calendar of the app's own so they reach the phone.
@MainActor
final class CalendarAccess {
    private let events = EKEventStore()

    /// macOS asks for permission using the reason in Info.plist; without one (a `swift run` build) asking would crash.
    static var available: Bool { Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil }

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        guard Self.available else { return false }
        if authorized { return true }
        return (try? await events.requestFullAccessToEvents()) ?? false
    }

    // MARK: Reading a timetable

    struct CalendarInfo: Identifiable, Hashable { let id: String; let title: String; let account: String }

    func calendars() -> [CalendarInfo] {
        guard authorized else { return [] }
        return events.calendars(for: .event).filter { $0.title != CalendarMirror.calendarTitle }
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func classes(calendarIds: [String], from: Date, to: Date) -> [Timetable.Instance] {
        guard authorized else { return [] }
        let cals = calendarIds.compactMap { events.calendar(withIdentifier: $0) }
        guard !cals.isEmpty else { return [] }
        return events.events(matching: events.predicateForEvents(withStart: from, end: to, calendars: cals)).map { e in
            Timetable.markCancelled(Timetable.Instance(
                uid: "\(e.calendarItemIdentifier)@\(ISO.instant(e.startDate))", summary: e.title ?? "", start: e.startDate,
                end: e.isAllDay ? nil : e.endDate, allDay: e.isAllDay, location: e.location?.nilIfBlank, cancelled: e.status == .canceled))
        }
    }

    // MARK: Copying deadlines

    /// Makes the app's calendar hold exactly these deadlines. Returns a problem to show, or nil.
    func mirror(_ entries: [CalendarMirror.Entry], store: BookStore) -> String? {
        guard authorized else { return "Study Tracker isn't allowed to use Calendar. Allow it in System Settings › Privacy & Security › Calendars." }
        guard let calendar = mirrorCalendar(store: store) else { return "Couldn't make a calendar for the deadlines." }
        let now = Date()
        let existing = events.events(matching: events.predicateForEvents(withStart: now.addingTimeInterval(-60 * 86_400),
                                                                         end: now.addingTimeInterval(730 * 86_400), calendars: [calendar]))
        let byId = Dictionary(existing.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let plan = CalendarMirror.plan(entries: entries, stored: store.mirrorState(), inCalendar: Set(byId.keys))
        do {
            for id in plan.delete { if let e = byId[id] { try events.remove(e, span: .thisEvent, commit: false) } }
            for u in plan.update {
                guard let e = byId[u.eventId] else { continue }
                fill(e, u.entry)
                try events.save(e, span: .thisEvent, commit: false)
                store.setMirrored(u.entry.deadlineId, eventId: e.calendarItemIdentifier, fingerprint: u.entry.fingerprint)
            }
            var made: [(EKEvent, CalendarMirror.Entry)] = []
            for entry in plan.create {
                let e = EKEvent(eventStore: events)
                e.calendar = calendar
                fill(e, entry)
                try events.save(e, span: .thisEvent, commit: false)
                made.append((e, entry))
            }
            try events.commit()
            // Identifiers are final once committed.
            for (e, entry) in made { store.setMirrored(entry.deadlineId, eventId: e.calendarItemIdentifier, fingerprint: entry.fingerprint) }
        } catch {
            events.reset()
            return "Couldn't update the deadlines calendar: \(error.localizedDescription)"
        }
        return nil
    }

    /// Takes the app's calendar away when copying is turned off.
    func removeMirror(store: BookStore) {
        if authorized, let cal = mirrorCalendar(store: store, create: false) { try? events.removeCalendar(cal, commit: true) }
        store.setSetting("mirror_calendar_id", nil)
        store.clearMirrorState()
    }

    private func fill(_ e: EKEvent, _ entry: CalendarMirror.Entry) {
        e.title = entry.title
        e.startDate = entry.due
        e.endDate = entry.due
        e.url = entry.url.flatMap(URL.init(string:))
    }

    /// The app's calendar, made in iCloud when there is an iCloud account so the phone sees it.
    private func mirrorCalendar(store: BookStore, create: Bool = true) -> EKCalendar? {
        if let id = store.setting("mirror_calendar_id"), let cal = events.calendar(withIdentifier: id) { return cal }
        if let cal = events.calendars(for: .event).first(where: { $0.title == CalendarMirror.calendarTitle && $0.allowsContentModifications }) {
            store.setSetting("mirror_calendar_id", cal.calendarIdentifier)
            return cal
        }
        guard create else { return nil }
        let sources = events.sources
        guard let source = sources.first(where: { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") })
            ?? events.defaultCalendarForNewEvents?.source ?? sources.first(where: { $0.sourceType == .local }) else { return nil }
        let cal = EKCalendar(for: .event, eventStore: events)
        cal.title = CalendarMirror.calendarTitle
        cal.source = source
        do { try events.saveCalendar(cal, commit: true) } catch { return nil }
        store.setSetting("mirror_calendar_id", cal.calendarIdentifier)
        store.clearMirrorState()
        return cal
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
