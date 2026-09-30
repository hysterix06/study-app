import SwiftUI
import StudyCore

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
        case .claude:
            switch claude.connectionState() {
            case .connected, .extensionInstalled:
                return .connected(claude.findCLI() != nil ? "Claude Desktop and Claude Code" : "Claude Desktop")
            case .stalePath: return .needsAttention("Reconnect to Claude Desktop")
            case .notConnected: return claude.findCLI() != nil ? .connected("Claude Code") : .notConnected
            }
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
        case .claude: return "sparkles"
        case .apple: return "applelogo"
        }
    }

    var blurb: String {
        switch self {
        case .moodle: return "Courses, deadlines, grades and files from your school."
        case .calendars: return "Your timetable, and busy time the planner works around."
        case .claude: return "Claude reads your lectures and saves concepts, questions and sheets back here."
        case .apple: return "Classes, deadlines and study blocks on your iPhone and Watch."
        }
    }

    var primaryAction: String {
        switch self {
        case .moodle: return "Connect Moodle"
        case .calendars: return "Add timetable"
        case .claude: return "Connect Claude"
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

struct ConnectionsScreen: View {
    @Environment(AppModel.self) var model
    var kind: ConnectionKind?

    var body: some View {
        let _ = model.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let kind {
                    HStack(spacing: 10) {
                        Image(systemName: kind.icon).font(.system(size: 22)).foregroundStyle(Theme.textSecondary)
                        Text(kind.title).font(.stTitle)
                        Spacer()
                        let status = model.connectionStatus(kind)
                        HStack(spacing: 6) { StatusDot(status: status); Text(status.title).font(.stSmall).foregroundStyle(Theme.textSecondary) }
                    }
                    switch kind {
                    case .moodle: MoodleSettings()
                    case .calendars: CalendarSettings()
                    case .claude: ClaudeSettings()
                    case .apple: AppleSyncSettings()
                    }
                } else {
                    Text("Connections").font(.stTitle)
                    Text("Everything Study Tracker talks to. Each one is optional, and your data stays on this Mac.")
                        .font(.stBody).foregroundStyle(Theme.textSecondary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(ConnectionKind.allCases) { k in ConnectionCard(kind: k) }
                    }
                    if model.store.boolSetting("setup_checklist_hidden") {
                        SetupChecklist(showsHide: false)
                    }
                }
            }
            .padding(28).contentWidth()
        }
    }
}

struct ConnectionCard: View {
    @Environment(AppModel.self) var model
    var kind: ConnectionKind

    var body: some View {
        let status = model.connectionStatus(kind)
        Button { model.go(.connections(kind)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: kind.icon).font(.system(size: 18)).foregroundStyle(Theme.textSecondary)
                    Text(kind.title).font(.stBodyStrong)
                    Spacer()
                    StatusDot(status: status)
                    Text(status.title).font(.stSmall).foregroundStyle(status.needsAttention ? Theme.attention : Theme.textSecondary)
                }
                Text(status.detail ?? kind.blurb).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(status.isConnected ? "Manage" : status.needsAttention ? "Fix" : kind.primaryAction)
                    .font(.stSmallStrong).foregroundStyle(status.needsAttention ? Theme.attention : Theme.textPrimary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard)
                .strokeBorder(status.needsAttention ? Theme.attention.opacity(0.4) : status.isConnected ? Theme.success.opacity(0.3) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
