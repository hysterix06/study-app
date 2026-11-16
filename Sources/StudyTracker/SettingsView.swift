import SwiftUI
import StudyCore

/// Settings (⌘,): one tab each for Moodle, the timetable, Claude and hidden courses.
struct SettingsView: View {
    enum Pane: String { case moodle, timetable, claude, courses }

    @Environment(AppModel.self) var model
    @AppStorage("settings.pane") private var pane: Pane = .moodle

    var body: some View {
        let _ = model.revision
        TabView(selection: $pane) {
            tab { MoodleSettings() }
                .tabItem { Label("Moodle", systemImage: "graduationcap") }.tag(Pane.moodle)
            tab { TimetableSettings() }
                .tabItem { Label("Timetable", systemImage: "calendar") }.tag(Pane.timetable)
            tab { ClaudeSettings() }
                .tabItem { Label("Claude", systemImage: "sparkles") }.tag(Pane.claude)
            tab { HiddenCoursesSettings() }
                .tabItem { Label("Courses", systemImage: "books.vertical") }.tag(Pane.courses)
        }
        .frame(width: 540, height: 440)
    }

    private func tab(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }.formStyle(.grouped)
    }
}

private struct MoodleSettings: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Section("Moodle") {
            if let site = model.moodleSite {
                LabeledContent("School", value: model.moodleSiteName ?? site.host ?? "")
                if let user = model.moodleUserName { LabeledContent("Signed in as", value: user) }
                LabeledContent("Last sync") {
                    Text(model.lastSync.map { Format.relative.localizedString(for: $0, relativeTo: Date()) } ?? "Never")
                }
                if let status = model.lastStatus { Text(status).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button(model.syncing ? "Syncing…" : "Sync now") { Task { await model.sync() } }.disabled(model.syncing)
                    Spacer()
                    Button("Sign out", role: .destructive) { model.signOut() }
                }
            } else {
                Text("Not connected. Connect Moodle from the main window.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ClaudeSettings: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Section("Claude") {
            if let engine = model.engineChoice {
                LabeledContent("Writing books with", value: engine == .claudeCode ? "Claude Code (your Claude plan)" : "Anthropic API key")
                Picker("Model", selection: Binding(get: { model.model }, set: { model.setModel($0) })) {
                    ForEach(engine == .claudeCode ? ClaudeCodeProvider.models : AnthropicProvider.models, id: \.id) { m in Text(m.name).tag(m.id) }
                }
                if let until = model.books.pausedUntil, until > Date() {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paused until \(Format.time(until))").font(.callout)
                        if let reason = model.books.pausedReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                    }
                } else if let writing = model.books.writing {
                    Text("Writing \(writing)…").font(.callout).foregroundStyle(.secondary)
                }
                Button("Turn Claude off", role: .destructive) { model.stopWritingBooks() }
            } else {
                Text("Claude is off. Study Tracker isn't using any of your tokens: no books are written and no pictures are read.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.claudeCLI != nil {
                    HStack {
                        Button("Turn on with Claude Code") { model.choose(.claudeCode) }
                        Text("About 150,000–200,000 tokens per course.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct HiddenCoursesSettings: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Section("Hidden courses") {
            if model.hiddenCourses.isEmpty {
                Text("No hidden courses.").foregroundStyle(.secondary)
            }
            ForEach(model.hiddenCourses) { c in
                HStack {
                    Text(c.title)
                    Spacer()
                    Button("Show") { model.setHidden(c, false) }
                }
            }
        }
    }
}
