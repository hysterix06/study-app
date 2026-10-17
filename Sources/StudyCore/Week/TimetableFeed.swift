import Foundation

/// The timetable link: Outlook's "Publish a calendar" ICS link, or any https or webcal .ics link. It's fetched every
/// half hour and the text kept, so the week shows without a network. The link itself is a secret (anyone holding it
/// can read the calendar), so it lives in the Keychain.
public enum TimetableFeed {
    public static let account = "timetable-url"
    public static let refreshInterval: TimeInterval = 30 * 60

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badLink, http(Int), notCalendar, network(String), moodleCalendar
        public var description: String {
            switch self {
            case .badLink: return "That isn't a calendar link. It should start with https:// or webcal:// and usually ends in .ics."
            case .http(401), .http(403): return "The calendar server refused the link. Publish the calendar again and copy the new ICS link."
            case .http(404): return "Nothing was found at that link. It may have been unpublished; publish the calendar again."
            case .http(let code): return "The calendar server answered with an error (\(code)). Trying again later."
            case .notCalendar: return "That link didn't return a calendar. Use the ICS link, not the HTML one."
            case .network(let m): return "Couldn't reach the calendar: \(m)"
            case .moodleCalendar:
                return "That's your Moodle calendar. Study Tracker already gets your deadlines from Moodle, and that calendar has no class times. Your classes are in Outlook: publish your Outlook calendar and paste its ICS link instead."
            }
        }
    }

    /// "webcal://…" becomes "https://…". Anything that isn't a web link is nil.
    public static func normalize(_ link: String) -> URL? {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["webcals://", "webcal://"] where s.lowercased().hasPrefix(scheme) { s = "https://" + s.dropFirst(scheme.count) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// Downloads the calendar and checks it is one. Returns the text and how many events it holds.
    public static func fetch(_ url: URL, transport: HTTPTransport = URLSessionTransport()) async throws -> (text: String, events: Int) {
        // Moodle's own calendar export holds the deadlines the Moodle sync already has, and no classes.
        if url.path.hasSuffix("/calendar/export_execute.php") { throw Failure.moodleCalendar }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("text/calendar, */*;q=0.5", forHTTPHeaderField: "Accept")
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await transport.data(for: req) } catch { throw Failure.network(error.localizedDescription) }
        guard (200..<300).contains(resp.statusCode) else { throw Failure.http(resp.statusCode) }
        let text = String(decoding: data, as: UTF8.self)
        guard let events = try? ICS.parse(text) else { throw Failure.notCalendar }
        if text.range(of: "PRODID:-//Moodle", options: .caseInsensitive) != nil { throw Failure.moodleCalendar }
        return (text, events.count)
    }
}

extension BookStore {
    /// The timetable as last fetched, if any.
    public var timetableText: String? { setting("timetable_ics") }
    public var timetableFetchedAt: Date? { setting("timetable_fetched_at").flatMap { ISO.parse($0) } }

    public func saveTimetable(_ text: String, events: Int, now: Date = Date()) {
        setSetting("timetable_ics", text)
        setSetting("timetable_fetched_at", ISO.instant(now))
        setSetting("timetable_status", "\(events) events")
    }

    public func clearTimetable() {
        for key in ["timetable_ics", "timetable_fetched_at", "timetable_status"] { setSetting(key, nil) }
    }

    /// Classes from the stored timetable for these days.
    public func classes(from: LocalDate, to: LocalDate, tz: TimeZone = .current) -> [Timetable.Instance] {
        guard let text = timetableText, let events = try? ICS.parse(text) else { return [] }
        return Timetable.occurrences(events, from: from, to: to, tz: tz)
    }
}
