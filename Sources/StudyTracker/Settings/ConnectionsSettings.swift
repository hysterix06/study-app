import SwiftUI
import StudyCore
import StudyAI

/// What each connection is doing, shown as a dot in the sidebar and a card on the Connections screen.
enum ConnectionStatus: Equatable {
    case connected(String), syncing, needsAttention(String), notConnected

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .syncing: return "Syncing"
        case .needsAttention: return "Needs attention"
        case .notConnected: return "Not connected"
        }
    }

    var detail: String? {
        switch self {
        case .connected(let d), .needsAttention(let d): return d
        default: return nil
        }
    }

    var needsAttention: Bool { if case .needsAttention = self { return true }; return false }
    var isConnected: Bool { if case .connected = self { return true }; return self == .syncing }
}

extension AppModel {
    func connectionStatus(_ kind: ConnectionKind) -> ConnectionStatus {
        switch kind {
        case .moodle:
            guard moodle.isConnected else { return .notConnected }
            if store.boolSetting("moodle_needs_signin") { return .needsAttention("Sign-in expired") }
            if moodle.syncing { return .syncing }
            return .connected(store.setting("moodle_site_name") ?? "Moodle")
        case .calendars:
            let sources = store.calendarSources()
            guard !sources.isEmpty else { return .notConnected }
            if let bad = sources.first(where: { ($0.lastStatus ?? "").hasPrefix("Failed") }) { return .needsAttention("\(bad.name) could not be updated") }
            return .connected("\(sources.count) calendar\(sources.count == 1 ? "" : "s")")
        case .ai:
            let stale = Connectors.all.filter { if case .stale = ai.state($0) { return true }; return false }
            if let s = stale.first { return .needsAttention("Reconnect \(s.name)") }
            if let chosen = ai.settings.everyday, !ai.engineOptions().contains(where: { $0.ref.providerId == chosen.providerId }) {
                return .needsAttention("\(chosen.displayName) needs attention")
            }
            let engine = ai.engine(for: .sortFiles)?.displayName
            let apps = Connectors.all.filter { ai.state($0) == .connected || ai.lastUsed($0) != nil }.map(\.name)
            let parts = ([engine] + apps.prefix(2).map { Optional($0) }).compactMap { $0 }
            return parts.isEmpty ? .notConnected : .connected(parts.joined(separator: " · "))
        case .apple:
            let cal = store.boolSetting("calendar_sync_enabled"), rem = store.boolSetting("reminders_sync_enabled")
            guard cal || rem else { return .notConnected }
            return .connected([cal ? "Calendar" : nil, rem ? "Reminders" : nil].compactMap { $0 }.joined(separator: " and "))
        }
    }

    var anyConnectionNeedsAttention: Bool { ConnectionKind.allCases.contains { connectionStatus($0).needsAttention } }
}

extension ConnectionKind {
    var icon: String {
        switch self {
        case .moodle: return "graduationcap"
        case .calendars: return "calendar.badge.plus"
        case .ai: return "sparkles"
        case .apple: return "applelogo"
        }
    }

    var blurb: String {
        switch self {
        case .moodle: return "Courses, deadlines, grades and files from your school."
        case .calendars: return "Your timetable, and busy time the planner works around."
        case .ai: return "Free AI sorts and reads your files; the course builder lays out each course."
        case .apple: return "Classes, deadlines and study blocks on your iPhone and Watch."
        }
    }

    var primaryAction: String {
        switch self {
        case .moodle: return "Connect Moodle"
        case .calendars: return "Add timetable"
        case .ai: return "Set up AI"
        case .apple: return "Turn on"
        }
    }
}

/// A small status dot: success when connected, attention when something needs fixing, none otherwise.
struct StatusDot: View {
    var status: ConnectionStatus
    var body: some View {
        Circle()
            .fill(status.needsAttention ? Theme.attention : status.isConnected ? Theme.success : Theme.clear)
            .overlay(Circle().strokeBorder(status.isConnected || status.needsAttention ? Theme.clear : Theme.textTertiary))
            .frame(width: 7, height: 7)
            .accessibilityLabel(status.title)
    }
}

/// Settings › Connections: Moodle, calendars and Apple Calendar, each optional.
struct ConnectionsSettings: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 26) {
            ForEach([ConnectionKind.moodle, .calendars, .apple]) { kind in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: kind.icon).foregroundStyle(Theme.textSecondary)
                        Text(kind.title).font(.stHeading)
                        Spacer()
                        let status = model.connectionStatus(kind)
                        StatusDot(status: status)
                        Text(status.detail ?? status.title).font(.stSmall).foregroundStyle(Theme.textSecondary)
                    }
                    Text(kind.blurb).font(.stSmall).foregroundStyle(Theme.textTertiary)
                    switch kind {
                    case .moodle: MoodleSettings()
                    case .calendars: CalendarSettings()
                    case .apple: AppleSyncSettings()
                    case .ai: EmptyView()
                    }
                }
            }
        }
    }
}
