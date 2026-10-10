import Foundation

/// Every screen, tab, Settings section and object has an address. Buttons, the command palette, the menu bar,
/// notifications and toasts all navigate by route, and the same routes work as `studytracker://…` URLs.
public enum Route: Hashable, Codable {
    /// The next session, the courses and what's due.
    case home
    /// Files the app isn't sure about, deadlines to confirm, conflicts, sign-ins and failed AI work.
    case needsLook
    /// The schedule: calendar and assignments.
    case calendar(CalendarMode, LocalDate?)
    /// A class, event (`p12:2026-09-30`, `e5`) or study block (`b7`) with its popover open.
    case occurrence(String)
    case assignments
    case assignment(Int)
    case course(Int, CourseTab)
    /// One topic of a course's path.
    case topic(Int)
    /// One course file's page (`file/9`; older links say `material/9`).
    case material(Int)
    case settings(SettingsPane)
    case setup(SetupStep)

    public static let scheme = "studytracker"

    // MARK: Paths

    public var path: String {
        switch self {
        case .home: return "home"
        case .needsLook: return "needs-a-look"
        case .calendar(let m, let d): return d.map { "calendar/\(m.rawValue)/\($0.string)" } ?? "calendar/\(m.rawValue)"
        case .occurrence(let key): return "calendar/occurrence/\(key)"
        case .assignments: return "assignments"
        case .assignment(let id): return "assignment/\(id)"
        case .course(let id, let tab): return "course/\(id)/\(tab.rawValue)"
        case .topic(let id): return "topic/\(id)"
        case .material(let id): return "file/\(id)"
        case .settings(let s): return "settings/\(s.rawValue)"
        case .setup(let s): return "setup/\(s.rawValue)"
        }
    }

    /// Paths from older versions still open: Today and Study are Home now, the Inbox is Needs a look, Connections and
    /// Activity are in Settings, and old course tabs open their new homes.
    public init?(path raw: String) {
        let p = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let head = p.first else { return nil }
        let rest = Array(p.dropFirst())
        func int(_ i: Int) -> Int? { rest.indices.contains(i) ? Int(rest[i]) : nil }
        switch (head, rest.count) {
        case ("home", 0), ("today", 0): self = .home
        case ("study", 0), ("study", 1): self = .home
        case ("review", 0): self = .home
        case ("review", 2) where rest[0] == "course" && int(1) != nil: self = .home
        case ("needs-a-look", 0), ("inbox", 0): self = .needsLook
        case ("inbox", 1):
            guard InboxSection(rawValue: rest[0]) != nil else { return nil }
            self = .needsLook
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
            let tab = rest.count == 2 ? CourseTab(name: rest[1]) : .path
            guard let tab else { return nil }
            self = .course(id, tab)
        case ("topic", 1):
            guard let id = int(0) else { return nil }
            self = .topic(id)
        case ("file", 1), ("material", 1):
            guard let id = int(0) else { return nil }
            self = .material(id)
        case ("connections", 0): self = .settings(.connections)
        case ("connections", 1):
            guard let k = ConnectionKind(name: rest[0]) else { return nil }
            self = .settings(k == .ai ? .ai : .connections)
        case ("activity", 0): self = .settings(.ai)
        case ("activity", 1):
            guard int(0) != nil else { return nil }
            self = .settings(.ai)
        case ("settings", 0): self = .settings(.general)
        case ("settings", 1):
            guard let s = SettingsPane(name: rest[0]) else { return nil }
            self = .settings(s)
        case ("setup", 0): self = .setup(.welcome)
        case ("setup", 1):
            guard let s = SetupStep(name: rest[0]) else { return nil }
            self = .setup(s)
        default: return nil
        }
    }

    // MARK: URLs

    public var url: URL { URL(string: "\(Route.scheme)://\(path)")! }

    /// `studytracker://course/3/notebook`: the host is the first path component.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Route.scheme else { return nil }
        let host = url.host(percentEncoded: false) ?? ""
        let tail = url.path(percentEncoded: false)
        self.init(path: host + tail)
    }

    // MARK: Screens

    /// The sidebar row this route lives under; returning to it restores its last route.
    public var screen: ScreenKey {
        switch self {
        case .home, .needsLook: return .home
        case .calendar, .occurrence, .assignments, .assignment: return .schedule
        case .course(let id, _): return .course(id)
        case .topic, .material: return .home
        case .settings: return .settings
        case .setup: return .setup
        }
    }

    public enum ScreenKey: Hashable, Codable {
        case home, schedule, course(Int), settings, setup
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
    case path, notebook, angles, files, deadlines
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// Tabs from older versions open their new homes: Materials is Files, Assignments is Deadlines, and the overview,
    /// concepts, notes and cards live in the path now.
    public init?(name: String) {
        switch name {
        case "materials": self = .files
        case "assignments": self = .deadlines
        case "overview", "concepts", "notes", "cards": self = .path
        default: self.init(rawValue: name)
        }
    }
}

public enum StudySegment: String, CaseIterable, Identifiable, Codable, Sendable {
    case today, lectures, insights
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ConnectionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case moodle, calendars, ai, apple
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .moodle: return "Moodle"
        case .calendars: return "Calendars"
        case .ai: return "AI"
        case .apple: return "Apple Calendar"
        }
    }

    /// Also accepts names from older links ("claude" is now "ai").
    public init?(name: String) {
        self.init(rawValue: name == "claude" ? "ai" : name)
    }
}

public enum SettingsPane: String, CaseIterable, Identifiable, Codable, Sendable {
    case general, study, terms, ai, connections, notifications, appearance, data, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "General"
        case .study: return "Study"
        case .terms: return "Terms and breaks"
        case .ai: return "AI"
        case .connections: return "Connections"
        case .notifications: return "Notifications"
        case .appearance: return "Appearance"
        case .data: return "Data and export"
        case .advanced: return "Advanced"
        }
    }

    /// Also accepts names from older links ("planner" is now "study").
    public init?(name: String) {
        self.init(rawValue: name == "planner" ? "study" : name)
    }
}

/// First run, in four steps: welcome, school (Moodle and courses), AI, done.
public enum SetupStep: String, CaseIterable, Identifiable, Codable, Sendable {
    case welcome, school, ai, done
    public var id: String { rawValue }

    /// Also accepts steps saved by older versions.
    public init?(name: String) {
        switch name {
        case "moodle", "term", "timetable": self = .school
        case "claude": self = .ai
        case "files": self = .done
        default: self.init(rawValue: name)
        }
    }
}
