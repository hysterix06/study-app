import SwiftUI
import EventKit
import StudyCore
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, terms, calendars, moodle, claude, apple, data
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .terms: return "Terms and breaks"
        case .calendars: return "Calendars"
        case .moodle: return "Moodle"
        case .claude: return "Claude"
        case .apple: return "Apple Calendar and alerts"
        case .data: return "Data and export"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .terms: return "calendar.badge.clock"
        case .calendars: return "calendar.badge.plus"
        case .moodle: return "graduationcap"
        case .claude: return "sparkles"
        case .apple: return "bell.badge"
        case .data: return "externaldrive"
        }
    }

    /// Until Settings moves to its own window, connections and preference panes share this in-window screen.
    init(route: Route) {
        switch route {
        case .settings(.terms): self = .terms
        case .settings(.notifications): self = .apple
        case .settings(.data): self = .data
        case .connections(.calendars): self = .calendars
        case .connections(.claude): self = .claude
        case .connections(.apple): self = .apple
        case .connections: self = .moodle
        default: self = .general
        }
    }

    var route: Route {
        switch self {
        case .general: return .settings(.general)
        case .terms: return .settings(.terms)
        case .data: return .settings(.data)
        case .calendars: return .connections(.calendars)
        case .moodle: return .connections(.moodle)
        case .claude: return .connections(.claude)
        case .apple: return .connections(.apple)
        }
    }
}

struct SettingsScreen: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let _ = model.revision
        let section = SettingsSection(route: model.route)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { section }, set: { if let s = $0 { model.go(s.route, replace: true) } })) {
                    ForEach(SettingsSection.allCases) { s in Label(s.title, systemImage: s.icon).tag(s) }
                }
                Text("Study Tracker | v\(appVersion)").font(.stSmall).foregroundStyle(Theme.tertiaryText).textSelection(.enabled).padding(12)
            }.frame(width: 230)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(section.title).font(.stTitle)
                    switch section {
                    case .general: GeneralSettings()
                    case .terms: TermsSettings()
                    case .calendars: CalendarSettings()
                    case .moodle: MoodleSettings()
                    case .claude: ClaudeSettings()
                    case .apple: AppleSettings()
                    case .data: DataSettings()
                    }
                }
                .padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The bundle's version (set by scripts/build-app.sh); falls back when running unbundled via `swift run`.
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"

/// Binds a settings key to a String.
@MainActor
func settingBinding(_ model: AppModel, _ key: String, default def: String = "") -> Binding<String> {
    Binding(get: { model.store.setting(key) ?? def }, set: { model.store.setSetting(key, $0); model.refresh() })
}
@MainActor
func boolBinding(_ model: AppModel, _ key: String, default def: Bool = false) -> Binding<Bool> {
    Binding(get: { model.store.boolSetting(key, default: def) }, set: { model.store.setBool(key, $0); model.refresh() })
}

// MARK: General

struct GeneralSettings: View {
    @Environment(AppModel.self) var model
    var body: some View {
        Form {
            Picker("Time zone", selection: settingBinding(model, "default_timezone", default: TimeZone.current.identifier)) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
            }
            Picker("Week starts on", selection: settingBinding(model, "week_starts_on", default: "1")) { Text("Monday").tag("1"); Text("Sunday").tag("7") }
            TimeSetting(label: "Default due time", key: "default_due_time", def: "23:59")
            Toggle("Type dates as day/month (12/10 = 12 October)", isOn: boolBinding(model, "day_first_dates", default: model.store.dayFirstDates))
            Picker("Paper for Cornell sheets", selection: settingBinding(model, "paper_size", default: "a4")) { ForEach(PaperSize.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
            Section("Study planner") {
                TimeSetting(label: "Study window starts", key: "study_window_start", def: "08:00")
                TimeSetting(label: "Study window ends", key: "study_window_end", def: "22:00")
                Stepper("At most \(model.store.intSetting("max_study_minutes_per_day", default: 180) / 60) h of planned study a day",
                        value: Binding(get: { model.store.intSetting("max_study_minutes_per_day", default: 180) / 60 },
                                       set: { model.store.setSetting("max_study_minutes_per_day", "\($0 * 60)"); model.refresh() }), in: 1...10)
                Stepper("Exams need about \(Int(model.store.doubleSetting("default_hours_exam", default: 6))) h when no estimate is set",
                        value: Binding(get: { Int(model.store.doubleSetting("default_hours_exam", default: 6)) },
                                       set: { model.store.setSetting("default_hours_exam", "\($0)"); model.refresh() }), in: 1...40)
                Stepper("Other work needs about \(Int(model.store.doubleSetting("default_hours_other", default: 3))) h when no estimate is set",
                        value: Binding(get: { Int(model.store.doubleSetting("default_hours_other", default: 3)) },
                                       set: { model.store.setSetting("default_hours_other", "\($0)"); model.refresh() }), in: 1...40)
            }
        }.formStyle(.grouped)
    }
}

struct TimeSetting: View {
    @Environment(AppModel.self) var model
    var label: String
    var key: String
    var def: String
    var body: some View {
        DatePicker(label, selection: Binding(
            get: { LocalDate.today().at(LocalTime(model.store.setting(key) ?? def) ?? LocalTime(def)!, tz: .current) },
            set: { model.store.setSetting(key, LocalTime($0, tz: .current).string); model.refresh() }), displayedComponents: .hourAndMinute)
    }
}

// MARK: Terms

struct TermsSettings: View {
    @Environment(AppModel.self) var model
    @State private var editing: Term?
    var body: some View {
        let terms = model.store.terms()
        VStack(alignment: .leading, spacing: 12) {
            Text("Classes only appear inside a term. Breaks (holidays, reading weeks) skip classes automatically.").font(.stBody).foregroundStyle(Theme.secondaryText)
            ForEach(terms) { t in
                Panel {
                    HStack {
                        Text(t.name).font(.stBodyStrong)
                        if t.isCurrent { Chip(text: "Current") }
                        Spacer()
                        Text("\(t.startDate.string) → \(t.endDate.string)").font(.stSmall).monospacedDigit().foregroundStyle(Theme.secondaryText)
                        Button("Edit") { editing = t }.buttonStyle(.borderless)
                    }
                    BreaksEditor(term: t)
                }
            }
            Button("Add term") {
                let today = LocalDate.today(tz: model.tz)
                editing = Term(name: "", startDate: today, endDate: today.adding(days: 105), isCurrent: terms.isEmpty)
            }.buttonStyle(PrimaryButtonStyle())
        }
        .sheet(item: $editing) { t in TermEditor(term: t) }
    }
}

struct TermEditor: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var term: Term
    @State private var start = Date()
    @State private var end = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(term.id == 0 ? "New term" : "Edit term").font(.stHeading)
            Form {
                TextField("Name", text: $term.name, prompt: Text("Fall 2026"))
                DatePicker("Starts", selection: $start, displayedComponents: .date)
                DatePicker("Ends", selection: $end, displayedComponents: .date)
                Toggle("Current term", isOn: $term.isCurrent)
            }.formStyle(.grouped)
            HStack {
                if term.id != 0 { Button("Delete", role: .destructive) { model.run("Deleted \(term.name) and its courses.") { try model.store.trashTerm(term.id) }; dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    term.startDate = LocalDate(start, tz: .current); term.endDate = LocalDate(end, tz: .current)
                    model.run("Saved \(term.name).") { _ = try model.store.saveTerm(term); return nil }
                    dismiss()
                }.buttonStyle(PrimaryButtonStyle()).disabled(term.name.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { start = term.startDate.at(LocalTime(hour: 12, minute: 0), tz: .current); end = term.endDate.at(LocalTime(hour: 12, minute: 0), tz: .current) }
    }
}

struct BreaksEditor: View {
    @Environment(AppModel.self) var model
    var term: Term
    @State private var label = ""
    @State private var start = Date()
    @State private var end = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.store.breaks(termId: term.id)) { b in
                HStack {
                    Text(b.label ?? "Break").font(.stBody)
                    Text("\(b.startDate.string) → \(b.endDate.string)").font(.stSmall).monospacedDigit().foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Remove") { model.run("Removed break.") { try model.store.trashRow(kind: "break", table: "term_breaks", id: b.id, label: b.label ?? "break") } }.buttonStyle(.borderless).font(.stSmall)
                }
            }
            HStack {
                TextField("Break name", text: $label).frame(width: 150)
                DatePicker("", selection: $start, displayedComponents: .date).labelsHidden()
                Text("to")
                DatePicker("", selection: $end, displayedComponents: .date).labelsHidden()
                Button("Add break") {
                    model.run("Added \(label.isEmpty ? "break" : label).") {
                        _ = try model.store.saveBreak(TermBreak(termId: term.id, startDate: LocalDate(start, tz: .current), endDate: LocalDate(end, tz: .current), label: label.isEmpty ? nil : label))
                        return nil
                    }
                    label = ""
                }.buttonStyle(.borderless)
            }.font(.stSmall)
        }
    }
}

// MARK: Calendars

struct CalendarSettings: View {
    @Environment(AppModel.self) var model
    @State private var addingFeed = false
    var body: some View {
        let sources = model.store.calendarSources()
        VStack(alignment: .leading, spacing: 14) {
            Text("Import your timetable from Outlook or any calendar. Add work shifts as busy time so the planner works around them.")
                .font(.stBody).foregroundStyle(Theme.secondaryText)
            HStack {
                Button("Import .ics file…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "ics")!].compactMap { $0 }
                    if p.runModal() == .OK, let u = p.url { model.previewICS(fileURL: u) }
                }.buttonStyle(PrimaryButtonStyle())
                Button("Subscribe to a calendar link…") { addingFeed = true }.buttonStyle(QuietButtonStyle())
                Button("Sync now") { Task { await model.syncFeeds(silent: false) } }.buttonStyle(QuietButtonStyle()).disabled(!sources.contains { $0.kind == "feed" })
            }
            ForEach(sources) { s in
                HStack {
                    Image(systemName: s.kind == "feed" ? "link" : "doc")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.stBodyStrong)
                        Text("\(s.role == "busy" ? "Busy time" : "School") · \(s.lastSyncedAt.map { "updated \(RelativeTime.describe($0))" } ?? "never synced") · \(s.lastStatus ?? "")")
                            .font(.stSmall).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    }
                    Spacer()
                    Button("Remove") { model.run("Removed \(s.name).") { try model.store.removeCalendarSource(s.id); return nil } }.buttonStyle(.borderless)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtleFill))
            }
            Panel {
                Text("Where to find calendar links").font(.stBodyStrong)
                Text("Outlook on the web: Settings → Calendar → Shared calendars → Publish a calendar → copy the ICS link. If publishing is blocked, use File → Save Calendar in Outlook for Mac and import the file.")
                    .font(.stSmall).foregroundStyle(Theme.secondaryText)
                Text("Moodle: Calendar → Export calendar → All events → Get calendar URL. Connecting Moodle directly (Connections › Moodle) also brings grades and course files.")
                    .font(.stSmall).foregroundStyle(Theme.secondaryText)
                Text("Links contain private tokens. They are stored in your Mac's Keychain, never in the database or logs.").font(.stSmall).foregroundStyle(Theme.tertiaryText)
            }
        }
        .sheet(isPresented: $addingFeed) { FeedSheet() }
    }
}

struct FeedSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var name = "School calendar"
    @State private var url = ""
    @State private var role = "school"
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscribe to a calendar link").font(.stHeading)
            Form {
                TextField("Name", text: $name)
                TextField("Link (https:// or webcal://)", text: $url)
                Picker("This calendar is", selection: $role) { Text("School timetable and deadlines").tag("school"); Text("Busy time").tag("busy") }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Checking…" : "Add") {
                    working = true
                    Task {
                        do {
                            let id = try model.store.addCalendarSource(name: name, kind: "feed", role: role, feedURL: url)
                            let src = model.store.calendarSources().first { $0.id == id }!
                            let text = try await model.store.fetchFeed(src)
                            let plan = try model.store.planICSImport(text: text, role: role, sourceId: id)
                            model.icsPreview = ICSPreview(name: name, text: text, role: role, plan: plan, sourceId: id)
                            dismiss()
                        } catch { model.fail(error) }
                        working = false
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(url.isEmpty || working)
            }
        }.padding(20).frame(width: 480)
    }
}

// MARK: Claude

struct ClaudeSettings: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let svc = model.claude
        let state = svc.connectionState()
        let lastMCP = model.store.recentAudit(actor: "mcp", limit: 5)
        let cli = svc.findCLI()
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude reads your lectures through a small local server (MCP) and saves concepts, questions and sheets back here. The app works fully without it.")
                .font(.stBody).foregroundStyle(Theme.secondaryText)
            Panel {
                HStack {
                    Image(systemName: state == .connected || state == .extensionInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    Text(stateText(state)).font(.stBodyStrong)
                    Spacer()
                }
                HStack {
                    Button(state == .connected ? "Reconnect" : "Connect to Claude Desktop") {
                        do {
                            let backup = try svc.connectDesktop(store: model.store)
                            model.refresh()
                            model.show("Connected. Quit and reopen Claude Desktop to load Study Tracker." + (backup != nil ? " Your previous config was backed up." : ""))
                        } catch { model.fail(error) }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(svc.mcpBinary == nil)
                    if svc.mcpbBundle != nil {
                        Button("Install as extension instead") { if !svc.installExtension() { model.show("Claude Desktop was not found.", error: true) } }.buttonStyle(QuietButtonStyle())
                    }
                    Button("Copy config snippet") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(svc.configSnippet(store: model.store), forType: .string)
                        model.show("Config snippet copied.")
                    }.buttonStyle(QuietButtonStyle())
                    if state == .connected || state != .notConnected {
                        Button("Disconnect") { try? svc.disconnectDesktop(); model.refresh() }.buttonStyle(.borderless)
                    }
                }
            }
            Panel {
                SectionHeader(title: "Status")
                row("Database", model.store.paths.database.path)
                row("MCP server", svc.mcpBinary?.path ?? "Not found (build the app bundle)")
                row("Schema version", "database \(model.store.db.userVersion) · server expects \(Migrations.currentVersion) · \(model.store.db.userVersion == Migrations.currentVersion ? "match" : "MISMATCH")")
                row("Last Claude activity", lastMCP.first.map { "\($0.action) · \(RelativeTime.describe($0.at))" } ?? "none yet")
                if !lastMCP.isEmpty {
                    ForEach(Array(lastMCP.dropFirst().enumerated()), id: \.offset) { _, e in
                        Text("\(e.action) · \(RelativeTime.describe(e.at))").font(.stSmall).foregroundStyle(Theme.tertiaryText).padding(.leading, 170)
                    }
                }
            }
            Panel {
                SectionHeader(title: "Claude Code (optional, uses your Claude plan)")
                row("Command-line tool", cli?.path ?? "Not found")
                Text("With Claude Code installed, Process runs in the background and lectures can be processed as soon as they arrive, with no copy and paste. Conversations like recall and quizzes still happen in Claude Desktop.")
                    .font(.stSmall).foregroundStyle(Theme.secondaryText)
                Toggle("Use Claude Code for Process buttons", isOn: boolBinding(model, "use_claude_code", default: true)).disabled(cli == nil)
                Toggle("Process new lectures automatically once filed", isOn: boolBinding(model, "auto_process")).disabled(cli == nil)
                Button("Look again") { svc.resetCLICache(); model.refresh() }.buttonStyle(.borderless).font(.stSmall)
            }
            Panel {
                SectionHeader(title: "Prompts")
                Text("Every Copy prompt button produces self-contained text, so it works even if Claude Desktop doesn't show MCP prompts. In Claude Desktop you can also pick them from the + menu.")
                    .font(.stSmall).foregroundStyle(Theme.secondaryText)
                HStack {
                    Button("Copy weekly plan prompt") { model.copyPrompt("weekly_plan", [:]) }.buttonStyle(QuietButtonStyle())
                    Button("Open Claude") { model.openClaude() }.buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    func stateText(_ s: ClaudeService.ConnectionState) -> String {
        switch s {
        case .connected: return "Connected to Claude Desktop"
        case .extensionInstalled: return "Installed as a Claude Desktop extension"
        case .stalePath(let p): return "Connected, but pointing at an old location (\(p)). Reconnect to fix."
        case .notConnected: return model.claude.claudeDesktopInstalled ? "Not connected yet" : "Claude Desktop is not installed"
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.stSmall).foregroundStyle(Theme.secondaryText).frame(width: 160, alignment: .leading)
            Text(v).font(.stSmall).textSelection(.enabled).lineLimit(3)
        }
    }
}

// MARK: Apple Calendar and notifications

struct AppleSettings: View {
    @Environment(AppModel.self) var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send classes, deadlines and planned study to Apple Calendar and Reminders. Through iCloud they reach your iPhone, Apple Watch and widgets. This is one-way; edits stay in Study Tracker.")
                .font(.stBody).foregroundStyle(Theme.secondaryText)
            Form {
                Toggle("Show in Apple Calendar (a \"Study Tracker\" calendar)", isOn: Binding(
                    get: { model.store.boolSetting("calendar_sync_enabled") },
                    set: { on in
                        Task {
                            if on { let ok = await model.calendarSync.requestCalendarAccess(); model.store.setBool("calendar_sync_enabled", ok); if !ok { model.show("Calendar access was not granted. Allow it in System Settings → Privacy & Security → Calendars.", error: true) } else { model.calendarSync.sync() } }
                            else { model.store.setBool("calendar_sync_enabled", false); model.calendarSync.disableCalendar() }
                            model.refresh()
                        }
                    }))
                Toggle("Put deadlines in Reminders", isOn: Binding(
                    get: { model.store.boolSetting("reminders_sync_enabled") },
                    set: { on in
                        Task {
                            let ok = on ? await model.calendarSync.requestRemindersAccess() : false
                            model.store.setBool("reminders_sync_enabled", on && ok)
                            if on && !ok { model.show("Reminders access was not granted.", error: true) }
                            if ok { model.calendarSync.sync() }
                            model.refresh()
                        }
                    }))
                if let s = model.calendarSync.lastStatus { Text(s).font(.stSmall).foregroundStyle(Theme.secondaryText) }
                Section("Notifications") {
                    Toggle("Notify me about classes, deadlines and study blocks", isOn: Binding(
                        get: { model.store.boolSetting("notifications_enabled") },
                        set: { on in
                            Task {
                                let ok = on ? await model.notifications.requestPermission() : false
                                model.store.setBool("notifications_enabled", on && ok)
                                if on && !ok { model.show("Notifications are not allowed. Turn them on in System Settings → Notifications → Study Tracker.", error: true) }
                                await model.notifications.reschedule()
                                model.refresh()
                            }
                        }))
                    Stepper("Class reminder \(model.store.intSetting("class_notice_minutes", default: 10)) minutes before",
                            value: Binding(get: { model.store.intSetting("class_notice_minutes", default: 10) },
                                           set: { model.store.setSetting("class_notice_minutes", "\($0)"); model.refresh() }), in: 0...60, step: 5)
                    TimeSetting(label: "Morning summary at", key: "digest_time", def: "08:00")
                }
            }.formStyle(.grouped)
            Button("Export an .ics file for other calendar apps") {
                let url = model.store.paths.export.appendingPathComponent("study-tracker.ics")
                do { try Exporter.icsFeed(store: model.store).write(to: url, atomically: true, encoding: .utf8); NSWorkspace.shared.activateFileViewerSelecting([url]) }
                catch { model.fail(error) }
            }.buttonStyle(QuietButtonStyle())
        }
    }
}

// MARK: Data

/// Deleted courses, terms, files and cards stay here for 30 days (UI remap principle 5).
struct RecentlyDeletedPanel: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let _ = model.revision
        let items = model.store.trashItems()
        let tz = model.tz
        Panel {
            SectionHeader(title: "Recently Deleted")
            Text("Deleted items stay here for \(StudyStore.trashRetentionDays) days, then are removed for good.")
                .font(.stSmall).foregroundStyle(Theme.secondaryText)
            if items.isEmpty {
                Text("Nothing deleted recently.").font(.stBody).foregroundStyle(Theme.secondaryText).padding(.vertical, 4)
            }
            let days = Dictionary(grouping: items) { LocalDate($0.deletedAt, tz: tz) }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Text(Formatters.day(day.at(LocalTime(hour: 12, minute: 0), tz: tz), tz: tz)).font(.stSmallStrong).foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 4)
                ForEach(days[day] ?? []) { item in
                    HStack(spacing: 10) {
                        Image(systemName: icon(item.kind)).foregroundStyle(Theme.secondaryText).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.stBody).lineLimit(1)
                            Text("\(item.kind == "inbox_batch" ? "Inbox" : item.kind.capitalized) · \(Formatters.time(item.deletedAt, tz: tz))")
                                .font(.stSmall).foregroundStyle(Theme.tertiaryText)
                        }
                        Spacer()
                        Button("Restore") { model.run("Restored \(item.label).") { try model.store.restoreTrash(item.id); return nil } }
                            .buttonStyle(QuietButtonStyle())
                        Button("Delete now") { model.run { try model.store.deleteTrashNow(item.id); return nil } }
                            .buttonStyle(.borderless).font(.stSmall).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    func icon(_ kind: String) -> String {
        switch kind {
        case "course": return "books.vertical"
        case "term": return "calendar.badge.clock"
        case "material": return "doc"
        case "assignment": return "checklist"
        case "card": return "rectangle.stack"
        case "inbox_batch": return "tray"
        default: return "trash"
        }
    }
}

struct DataSettings: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let paths = model.store.paths
        VStack(alignment: .leading, spacing: 14) {
            RecentlyDeletedPanel()
            Panel {
                SectionHeader(title: "Your files")
                folder("Study Tracker folder", paths.root)
                folder("Inbox (drop files here)", paths.inbox)
                folder("Library", paths.library)
                folder("Exports", paths.export)
                HStack {
                    Text("Database").font(.stSmall).foregroundStyle(Theme.secondaryText).frame(width: 170, alignment: .leading)
                    Text(paths.database.path).font(.stSmall).textSelection(.enabled)
                }
            }
            Panel {
                SectionHeader(title: "Backups")
                Text("A copy is made every day (the last 14 are kept) and before Claude's first change in each session.").font(.stSmall).foregroundStyle(Theme.secondaryText)
                HStack {
                    Text(model.store.latestBackupDate().map { "Last backup \(RelativeTime.describe($0))" } ?? "No backup yet").font(.stBody)
                    Spacer()
                    Button("Back up now") { model.run("Backed up.") { _ = try model.store.backup(reason: "manual"); return nil } }.buttonStyle(QuietButtonStyle())
                    Button("Show backups") { NSWorkspace.shared.open(paths.backups) }.buttonStyle(QuietButtonStyle())
                }
            }
            Panel {
                SectionHeader(title: "Export")
                HStack {
                    Button("Export everything (JSON + Markdown)") {
                        do { let u = try Exporter.fullExport(store: model.store); NSWorkspace.shared.activateFileViewerSelecting([u]) } catch { model.fail(error) }
                    }.buttonStyle(PrimaryButtonStyle())
                    Button("Flashcards for Anki (.tsv)") {
                        let u = paths.export.appendingPathComponent("study-tracker-cards.tsv")
                        do { try Exporter.ankiExport(store: model.store, to: u); NSWorkspace.shared.activateFileViewerSelecting([u]) } catch { model.fail(error) }
                    }.buttonStyle(QuietButtonStyle())
                }
                Text("Anki: File → Import, choose the .tsv. Then review on your phone with AnkiMobile or AnkiDroid.").font(.stSmall).foregroundStyle(Theme.secondaryText)
                Divider()
                HStack {
                    Text(model.store.setting("obsidian_vault_path").map { "Obsidian vault: \($0)" } ?? "No Obsidian vault chosen").font(.stSmall).lineLimit(1)
                    Spacer()
                    Button("Choose vault…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { model.store.setSetting("obsidian_vault_path", u.path); model.refresh() }
                    }.buttonStyle(QuietButtonStyle())
                    Button("Export to Obsidian") {
                        guard let v = model.store.setting("obsidian_vault_path") else { return }
                        let dest = URL(fileURLWithPath: v).appendingPathComponent("Study Tracker")
                        do { try Exporter.markdownExport(store: model.store, to: dest, obsidian: true); model.show("Exported to \(dest.path).") } catch { model.fail(error) }
                    }.buttonStyle(QuietButtonStyle()).disabled(model.store.setting("obsidian_vault_path") == nil)
                }
                Text("One-way: Study Tracker writes into the vault and never reads from it.").font(.stSmall).foregroundStyle(Theme.tertiaryText)
            }
            Panel {
                SectionHeader(title: "Sample data")
                HStack {
                    Text(SampleData.isLoaded(model.store) ? "Sample courses are loaded." : "Try the app with a sample term, three courses and a lecture.").font(.stBody)
                    Spacer()
                    if SampleData.isLoaded(model.store) {
                        Button("Remove sample data") { model.run("Sample data removed.") { try SampleData.remove(model.store); return nil } }.buttonStyle(QuietButtonStyle())
                    } else {
                        Button("Load sample data") { model.run("Sample data loaded.") { try SampleData.load(model.store); return nil } }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }
    }

    func folder(_ label: String, _ url: URL) -> some View {
        HStack {
            Text(label).font(.stSmall).foregroundStyle(Theme.secondaryText).frame(width: 170, alignment: .leading)
            Text(url.path).font(.stSmall).lineLimit(1)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless).font(.stSmall)
        }
    }
}
