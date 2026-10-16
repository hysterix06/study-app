import SwiftUI
import StudyCore

struct SettingsView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Form {
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
            Section("Books") {
                if let engine = model.engineChoice {
                    LabeledContent("Written by", value: engine == .claudeCode ? "Claude Code (your Claude plan)" : "Anthropic API key")
                    Picker("Model", selection: Binding(get: { model.model }, set: { model.setModel($0) })) {
                        ForEach(engine == .claudeCode ? ClaudeCodeProvider.models : AnthropicProvider.models, id: \.id) { m in Text(m.name).tag(m.id) }
                    }
                    if let until = model.books.pausedUntil, until > Date() {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Paused until \(Format.time(until))").font(.callout)
                            if let reason = model.books.pausedReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                        }
                        Button("Try now") { model.resumeBooks() }
                    } else if let writing = model.books.writing {
                        Text("Writing \(writing)…").font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Stop writing books", role: .destructive) { model.stopWritingBooks() }
                } else {
                    Text(model.claudeCLI == nil ? "Books aren't being written. Install Claude Code or add an API key from Home."
                         : "Books aren't being written. Choose Claude Code from Home to start.")
                        .foregroundStyle(.secondary)
                    if model.claudeCLI != nil { Button("Use Claude Code") { model.choose(.claudeCode) } }
                }
            }
            if !model.hiddenCourses.isEmpty {
                Section("Hidden courses") {
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
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
