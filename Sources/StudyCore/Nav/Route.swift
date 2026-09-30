import Foundation

/// Every screen, tab, Settings section and object has an address. Buttons, the command palette, the menu bar,
/// notifications and toasts all navigate by route, and the same routes work as `studytracker://…` URLs.
public enum Route: Hashable, Codable {
    case today
    case inbox(InboxSection?)
    case calendar(CalendarMode, LocalDate?)
    /// A class, event (`p12:2026-09-30`, `e5`) or study block (`b7`) with its popover open.
    case occurrence(String)
    case assignments
    case assignment(Int)
    case course(Int, CourseTab)
    case material(Int)
    case study(StudySegment)
    case review(courseId: Int?)
    case connections(ConnectionKind?)
    case activity(jobId: Int?)
    case settings(SettingsPane)
    case setup(SetupStep)

    public static let scheme = "studytracker"

    // MARK: Paths

    public var path: String {
        switch self {
        case .today: return "today"
        case .inbox(let s): return s.map { "inbox/\($0.rawValue)" } ?? "inbox"
        case .calendar(let m, let d): return d.map { "calendar/\(m.rawValue)/\($0.string)" } ?? "calendar/\(m.rawValue)"
        case .occurrence(let key): return "calendar/occurrence/\(key)"
        case .assignments: return "assignments"
        case .assignment(let id): return "assignment/\(id)"
        case .course(let id, let tab): return "course/\(id)/\(tab.rawValue)"
        case .material(let id): return "material/\(id)"
        case .study(let s): return "study/\(s.rawValue)"
        case .review(let c): return c.map { "review/course/\($0)" } ?? "review"
        case .connections(let k): return k.map { "connections/\($0.rawValue)" } ?? "connections"
        case .activity(let j): return j.map { "activity/\($0)" } ?? "activity"
        case .settings(let s): return "settings/\(s.rawValue)"
        case .setup(let s): return "setup/\(s.rawValue)"
        }
    }

    public init?(path raw: String) {
        let p = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let head = p.first else { return nil }
        let rest = Array(p.dropFirst())
        func int(_ i: Int) -> Int? { rest.indices.contains(i) ? Int(rest[i]) : nil }
        switch (head, rest.count) {
        case ("today", 0): self = .today
        case ("inbox", 0): self = .inbox(nil)
        case ("inbox", 1):
            guard let s = InboxSection(rawValue: rest[0]) else { return nil }
            self = .inbox(s)
        case ("calendar", 0): self = .calendar(.week, nil)
        case ("calendar", 2) where rest[0] == "occurrence": self = .occurrence(rest[1])
        case ("calendar", 1), ("calendar", 2):
            guard let m = CalendarMode(rawValue: rest[0]) else { return nil }
            if rest.count == 2 {
                guard let d = LocalDate(rest[1]) else { return nil }
                self = .calendar(m, d)
            } else { self = .calendar(m, nil) }
        case ("assignments", 0): self = .assignments
        case ("assignment", 1):
            guard let id = int(0) else { return nil }
            self = .assignment(id)
        case ("course", 1), ("course", 2):
            guard let id = int(0) else { return nil }
            let tab = rest.count == 2 ? CourseTab(rawValue: rest[1]) : .overview
            guard let tab else { return nil }
            self = .course(id, tab)
        case ("material", 1):
            guard let id = int(0) else { return nil }
            self = .material(id)
        case ("study", 0): self = .study(.today)
        case ("study", 1):
            guard let s = StudySegment(rawValue: rest[0]) else { return nil }
            self = .study(s)
        case ("review", 0): self = .review(courseId: nil)
        case ("review", 2) where rest[0] == "course":
            guard let id = int(1) else { return nil }
            self = .review(courseId: id)
        case ("connections", 0): self = .connections(nil)
        case ("connections", 1):
            guard let k = ConnectionKind(rawValue: rest[0]) else { return nil }
            self = .connections(k)
        case ("activity", 0): self = .activity(jobId: nil)
        case ("activity", 1):
            guard let id = int(0) else { return nil }
            self = .activity(jobId: id)
        case ("settings", 0): self = .settings(.general)
        case ("settings", 1):
            guard let s = SettingsPane(rawValue: rest[0]) else { return nil }
            self = .settings(s)
        case ("setup", 0): self = .setup(.welcome)
        case ("setup", 1):
            guard let s = SetupStep(rawValue: rest[0]) else { return nil }
            self = .setup(s)
        default: return nil
        }
    }

    // MARK: URLs

    public var url: URL { URL(string: "\(Route.scheme)://\(path)")! }

    /// `studytracker://course/3/cards`: the host is the first path component.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Route.scheme else { return nil }
        let host = url.host(percentEncoded: false) ?? ""
        let tail = url.path(percentEncoded: false)
        self.init(path: host + tail)
    }

    // MARK: Screens

    /// The sidebar item this route lives under; returning to it restores its last route.
    public var screen: ScreenKey {
        switch self {
        case .today: return .today
        case .inbox: return .inbox
        case .calendar, .occurrence: return .calendar
        case .assignments, .assignment: return .assignments
        case .course(let id, _): return .course(id)
        case .material, .study: return .study
        case .review: return .study
        case .connections: return .connections
        case .activity: return .connections
        case .settings: return .settings
        case .setup: return .setup
        }
    }

    public enum ScreenKey: Hashable, Codable {
        case today, inbox, calendar, assignments, study, course(Int), connections, settings, setup
    }
}

public enum InboxSection: String, CaseIterable, Codable, Sendable {
    case files, ready, documents, deadlines, blocks, cards, conflicts, failed
}

public enum CalendarMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case week, month, agenda
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum CourseTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview, assignments, materials, concepts, notes, cards
    public var id: String { rawValue }
    public var title: String { self == .notes ? "Notes" : rawValue.capitalized }
}

public enum StudySegment: String, CaseIterable, Identifiable, Codable, Sendable {
    case today, lectures, insights
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ConnectionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case moodle, calendars, claude, apple
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .moodle: return "Moodle"
        case .calendars: return "Calendars"
        case .claude: return "Claude"
        case .apple: return "Apple Calendar"
        }
    }
}

public enum SettingsPane: String, CaseIterable, Identifiable, Codable, Sendable {
    case general, planner, terms, notifications, appearance, data, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "General"
        case .planner: return "Study planner"
        case .terms: return "Terms and breaks"
        case .notifications: return "Notifications"
        case .appearance: return "Appearance"
        case .data: return "Data and export"
        case .advanced: return "Advanced"
        }
    }
}

public enum SetupStep: String, CaseIterable, Identifiable, Codable, Sendable {
    case welcome, moodle, term, timetable, claude, files, done
    public var id: String { rawValue }
}
