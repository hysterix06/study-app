import SwiftUI
import AppKit
import StudyCore
import StudyAI

/// Connections › AI: the built-in AI (which engine runs what), accounts and keys, the student's own AI apps,
/// privacy and spending. Every part is optional; the app works without AI.
struct AISettingsView: View {
    @Environment(AppModel.self) var model
    @State private var keyFor: ProviderDescriptor?
    @State private var consentFor: ProviderDescriptor?
    @State private var busy: String?

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 16) {
            Text("AI turns lectures into concepts, questions, flashcards and Cornell sheets, and runs recall, quizzes and draft checks with you. Pick a built-in engine (several are free), connect an AI app you already use, or both.")
                .font(.stBody).foregroundStyle(Theme.textSecondary)
            BuiltInPanel(busy: $busy)
            EnginesPanel(keyFor: $keyFor, consentFor: $consentFor, busy: $busy)
            AIAppsPanel()
            UsagePanel()
            PrivacyPanel(consentFor: $consentFor)
            ChatsPanel()
            Panel { ActivityList(limit: 100) }
        }
        .sheet(item: $keyFor) { d in KeySheet(provider: d) { needsConsent in if needsConsent { consentFor = d } } }
        .sheet(item: $consentFor) { d in ConsentSheet(provider: d) }
    }
}

// MARK: Built-in AI

private struct BuiltInPanel: View {
    @Environment(AppModel.self) var model
    @Binding var busy: String?
    @State private var showTasks = false

    var body: some View {
        let ai = model.ai
        let options = ai.engineOptions()
        Panel {
            SectionHeader(title: "Built-in AI")
            if options.isEmpty {
                Text("No engine is ready yet. Turn one on below. The free ones are a good start: Apple Intelligence on this Mac, or OpenRouter's free models.")
                    .font(.stSmall).foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Text("Use").font(.stBody)
                Picker("", selection: Binding(get: { model.store.setting("ai_engine_default") ?? "" }, set: {
                    model.store.setSetting("ai_engine_default", $0.isEmpty ? nil : $0); model.refresh()
                })) {
                    Text("Best free engine (automatic)").tag("")
                    ForEach(options) { o in Text(o.title + (o.free ? " · free" : "")).tag(o.ref.string) }
                    Divider()
                    Text("My AI app (copy the prompt)").tag("handoff")
                }.labelsHidden().frame(maxWidth: 380)
            }
            if let current = ai.engine(for: .process) {
                Text("Lectures are processed with \(current.displayName). Conversations open in the chat here.\(ai.fit(.process, current).note.map { " \($0)" } ?? "")")
                    .font(.stSmall).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Tasks copy their prompt for \(ai.handoffApp?.name ?? "your AI app"), or for any chatbot.").font(.stSmall).foregroundStyle(Theme.textSecondary)
            }
            DisclosureGroup("Choose per task", isExpanded: $showTasks) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AITask.allCases, id: \.self) { task in
                        HStack {
                            Text(task.label).font(.stSmall).frame(width: 190, alignment: .leading)
                            Picker("", selection: Binding(get: { model.store.setting("ai_engine.\(task.rawValue)") ?? "" }, set: {
                                model.store.setSetting("ai_engine.\(task.rawValue)", $0.isEmpty ? nil : $0); model.refresh()
                            })) {
                                Text("Same as above").tag("")
                                ForEach(options) { o in
                                    let fit = ai.fit(task, o.ref)
                                    if fit.isUsable { Text(o.title + (fit.note != nil ? " (basic)" : "")).tag(o.ref.string) }
                                }
                                Text("My AI app").tag("handoff")
                            }.labelsHidden().frame(maxWidth: 300)
                            if let note = ai.engine(for: task).flatMap({ ai.fit(task, $0).note }) {
                                Image(systemName: "info.circle").foregroundStyle(Theme.textTertiary).help(note)
                            }
                        }
                    }
                }.padding(.top, 6)
            }.font(.stSmall)
            Toggle("Process new lectures automatically once filed", isOn: boolBinding(model, "auto_process"))
            if model.store.boolSetting("auto_process") {
                Toggle("…even with a paid engine or Claude Code (your plan)", isOn: boolBinding(model, "auto_process_paid")).font(.stSmall).padding(.leading, 18)
            }
            if model.ai.claudeCLI() != nil || model.ai.edition == .macDirect {
                HStack {
                    Text(model.ai.claudeCLI() != nil ? "Claude Code found: it can run background tasks on your Claude plan." : "Claude Code isn't installed.")
                        .font(.stSmall).foregroundStyle(Theme.textTertiary)
                    Button("Look again") { model.ai.resetCLICache(); model.refresh() }.buttonStyle(.borderless).font(.stSmall)
                }
                if model.ai.claudeCLI() != nil {
                    HStack {
                        Text("Claude Code model").font(.stSmall)
                        Picker("Claude Code model", selection: Binding(get: { model.ai.claudeModel },
                                                                      set: { model.store.setSetting("claude_code_model", $0); model.refresh() })) {
                            ForEach(ClaudeCodeProvider.models) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 260)
                    }
                    Text("A lecture takes a few requests about the size of its slides. Haiku stretches your plan furthest; Opus uses it fastest.")
                        .font(.stSmall).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: Engines

private struct EnginesPanel: View {
    @Environment(AppModel.self) var model
    @Binding var keyFor: ProviderDescriptor?
    @Binding var consentFor: ProviderDescriptor?
    @Binding var busy: String?

    var body: some View {
        Panel {
            SectionHeader(title: "Engines")
            Text("Free options are listed first. Keys stay in your Mac's Keychain.").font(.stSmall).foregroundStyle(Theme.textTertiary)
            let list = model.ai.providers.sorted { ($0.hasFreeOption ? 0 : 1) < ($1.hasFreeOption ? 0 : 1) }
            ForEach(list) { d in
                ProviderRow(provider: d, keyFor: $keyFor, consentFor: $consentFor, busy: $busy)
                if d.id != list.last?.id { Divider() }
            }
        }
    }
}

private struct ProviderRow: View {
    @Environment(AppModel.self) var model
    let provider: ProviderDescriptor
    @Binding var keyFor: ProviderDescriptor?
    @Binding var consentFor: ProviderDescriptor?
    @Binding var busy: String?
    @State private var testResult: String?

    var body: some View {
        let ai = model.ai
        let status = ai.status(provider)
        let blocked = ai.settings.freeTierBlocked(provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(provider.name).font(.stBodyStrong)
                Chip(text: provider.runsLocally || provider.isApple ? "Free" : provider.hasFreeOption && !blocked ? "Free tier" : "Paid")
                Spacer()
                switch status {
                case .ready:
                    Label("Ready", systemImage: "checkmark.circle.fill").font(.stSmall).foregroundStyle(Theme.success)
                case .unavailable(let why):
                    Text(why).font(.stSmall).foregroundStyle(Theme.textTertiary).lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
                case .needsKey:
                    if provider.auth == .apiKeyOrSignIn {
                        Button(busy == provider.id ? "Waiting for browser…" : "Sign in") { signIn() }.buttonStyle(PrimaryButtonStyle()).disabled(busy != nil)
                    }
                    Button("Add key") { keyFor = provider }.buttonStyle(QuietButtonStyle())
                case .needsConsent:
                    Button("Turn on") { consentFor = provider }.buttonStyle(PrimaryButtonStyle())
                }
            }
            Text(provider.blurb).font(.stSmall).foregroundStyle(Theme.textSecondary)
            Text(provider.dataUse.label).font(.stSmall)
                .foregroundStyle(provider.dataUse.needsTrainingConsent ? Theme.attention : Theme.textTertiary)
            if blocked { Text("Free tier not allowed in your region: use a paid key.").font(.stSmall).foregroundStyle(Theme.attention) }
            if status.isReady || status == .needsConsent, provider.needsKey || !provider.isApple {
                HStack(spacing: 12) {
                    if !provider.isApple { ModelMenu(provider: provider) }
                    Button("Test") { test() }.disabled(busy != nil)
                    if provider.needsKey { Button("Remove key") { ai.setKey("", for: provider); ai.settings.setConsent(provider.id, false); model.refresh() } }
                    else if status.isReady { Button("Turn off") { ai.settings.setConsent(provider.id, false); model.refresh() } }
                    if let url = provider.keyURL.flatMap(URL.init(string:)) { Link("Manage on \(URL(string: provider.keyURL!)?.host ?? "site")", destination: url) }
                }
                .buttonStyle(.borderless).font(.stSmall)
            } else if status == .needsKey, let url = provider.keyURL.flatMap(URL.init(string:)) {
                Link("Get a key", destination: url).font(.stSmall)
            }
            if let testResult { Text(testResult).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(3) }
        }
        .padding(.vertical, 4)
    }

    func signIn() {
        busy = provider.id
        Task {
            do {
                try await model.ai.signInWithOpenRouter()
                model.show("Signed in to OpenRouter.")
                if model.ai.settings.needsConsent(provider) { consentFor = provider }
            } catch { model.fail(error) }
            busy = nil
            model.refresh()
        }
    }

    func test() {
        busy = provider.id
        testResult = "Testing…"
        Task {
            do {
                var ref = model.ai.engineOptions().first { $0.ref.providerId == provider.id }?.ref ?? EngineRef(provider.id, model: provider.suggestedModel)
                if ref.model == nil, !provider.isApple { ref.model = try await model.ai.refreshModels(provider).first?.id }
                let p = try model.ai.factory.make(ref, edition: model.ai.edition, requireConsent: false)
                let start = Date()
                let r = try await p.send(ChatRequest(model: ref.model ?? provider.suggestedModel ?? "system", messages: [.user("Reply with the single word: ready")], maxOutputTokens: 20))
                testResult = "Works (\(String(format: "%.1f", Date().timeIntervalSince(start))) s): \"\(r.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))\""
            } catch {
                testResult = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            busy = nil
        }
    }
}

/// Picks the model for a provider (free ones first), from its live list.
private struct ModelMenu: View {
    @Environment(AppModel.self) var model
    let provider: ProviderDescriptor
    @State private var loading = false

    var body: some View {
        let s = model.ai.settings
        let models = (s.descriptor(provider.id)?.models ?? provider.models).sorted { ($0.free ? 0 : 1, $0.name) < ($1.free ? 0 : 1, $1.name) }
        let current = s.engine(forProvider: provider.id) ?? provider.suggestedModel ?? (provider.id == Catalog.openRouter.id ? Catalog.bestFreeModel(models)?.id : nil)
        Menu {
            ForEach(models.prefix(80)) { m in
                Button((m.free ? "★ " : "") + m.name + (m.tools ? "" : " (no tools)")) { choose(m.id) }
            }
            Divider()
            Button(loading ? "Loading…" : "Refresh list") { refresh() }
        } label: { Text(current.flatMap { id in models.first { $0.id == id }?.name ?? id } ?? "Choose model").font(.stSmall) }
            .menuStyle(.borderlessButton).fixedSize()
            .onAppear { if s.cachedModels(provider.id).isEmpty && model.ai.status(provider).isReady { refresh() } }
    }

    func choose(_ id: String) {
        let ref = EngineRef(provider.id, model: id)
        // Picking a model makes it the default when nothing else is chosen, or updates the default's model.
        if model.ai.settings.defaultEngine == nil || model.ai.settings.defaultEngine?.providerId == provider.id { model.ai.settings.defaultEngine = ref }
        for task in AITask.allCases where model.ai.settings.override(for: task)?.providerId == provider.id { model.ai.settings.setOverride(ref, for: task) }
        model.refresh()
    }

    func refresh() {
        loading = true
        Task { _ = try? await model.ai.refreshModels(provider); loading = false; model.refresh() }
    }
}

private struct KeySheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let provider: ProviderDescriptor
    var onSaved: (Bool) -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(provider.name) key").font(.stHeading)
            Text("Paste the key from \(provider.keyURL.flatMap { URL(string: $0)?.host } ?? "the provider's site"). It's stored in your Mac's Keychain and only sent to \(provider.name).")
                .font(.stSmall).foregroundStyle(Theme.textSecondary)
            SecureField("Key", text: $key).textFieldStyle(.roundedBorder)
            if let url = provider.keyURL.flatMap(URL.init(string:)) { Link("Get a key", destination: url).font(.stSmall) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.ai.setKey(key, for: provider)
                    dismiss()
                    Task { _ = try? await model.ai.refreshModels(provider); model.refresh() }
                    onSaved(model.ai.settings.needsConsent(provider))
                }.buttonStyle(PrimaryButtonStyle()).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 440)
    }
}

/// Asked once per provider, before any course material is sent to it.
struct ConsentSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let provider: ProviderDescriptor
    @State private var allowTraining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send your material to \(provider.name)?").font(.stHeading)
            VStack(alignment: .leading, spacing: 6) {
                bullet("Lecture text, speaker notes and, for some tasks, slide pictures or photos of your notes.")
                bullet("Your replies in study chats, and your draft when you ask for a draft check.")
                bullet("Assignment titles, dates and weights only for planning and draft checks. Grades are never sent.")
            }
            Text(provider.dataUse.label).font(.stSmallStrong).foregroundStyle(provider.dataUse.needsTrainingConsent ? Theme.attention : Theme.textPrimary)
            if provider.dataUse.needsTrainingConsent {
                Toggle(provider.id == Catalog.openRouter.id ? "Also allow free models that may train on my material (more free models)" : "I understand the free tier may train on my material",
                       isOn: $allowTraining).font(.stSmall)
                if provider.id == Catalog.openRouter.id && !allowTraining {
                    Text("Without this, OpenRouter only uses providers that don't train on your data. Some free models won't be available.").font(.stSmall).foregroundStyle(Theme.textTertiary)
                }
            }
            Text("Course slides belong to your school; check that sharing them with an AI service is allowed. You can turn this off any time in Connections › AI.")
                .font(.stSmall).foregroundStyle(Theme.textTertiary)
            HStack {
                Spacer()
                Button("Not now") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Agree and turn on") {
                    model.ai.settings.setConsent(provider.id, true)
                    model.ai.settings.setTrainingAllowed(provider.id, allowTraining)
                    dismiss(); model.refresh()
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 480)
        .onAppear { allowTraining = model.ai.settings.trainingAllowed(provider.id) }
    }

    func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(s) }.font(.stSmall).foregroundStyle(Theme.textSecondary)
    }
}

// MARK: AI apps

private struct AIAppsPanel: View {
    @Environment(AppModel.self) var model
    @State private var showUnsupported = false

    var body: some View {
        Panel {
            SectionHeader(title: "Your AI apps")
            Text("Let an AI app you already use read your material and save results here, through Study Tracker's local MCP server. Only the app you connect can reach it, and only on this Mac.")
                .font(.stSmall).foregroundStyle(Theme.textSecondary)
            let ai = model.ai
            let apps = Connectors.all.sorted { (ai.isInstalled($0) ? 0 : 1, $0.free ? 0 : 1) < (ai.isInstalled($1) ? 0 : 1, $1.free ? 0 : 1) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(apps) { c in ConnectorCard(connector: c) }
            }
            DisclosureGroup("Apps that can't connect, and what to do instead", isExpanded: $showUnsupported) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Connectors.unsupported) { u in
                        VStack(alignment: .leading, spacing: 1) { Text(u.name).font(.stSmallStrong); Text(u.reason).font(.stSmall).foregroundStyle(Theme.textSecondary) }
                    }
                    Text("Copy for any chatbot: lecture and syllabus tasks can copy a prompt for any chatbot, and you paste its answer back. It appears on those buttons when no engine is set up.")
                        .font(.stSmall).foregroundStyle(Theme.textTertiary)
                }.padding(.top, 6)
            }.font(.stSmall)
        }
    }
}

private struct ConnectorCard: View {
    @Environment(AppModel.self) var model
    let connector: AIAppConnector
    @State private var working = false

    var body: some View {
        let ai = model.ai
        let installed = ai.isInstalled(connector)
        let state = ai.state(connector)
        let last = ai.lastUsed(connector)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(connector.name).font(.stBodyStrong).lineLimit(1)
                Spacer()
                switch state {
                case .connected: Circle().fill(Theme.success).frame(width: 7, height: 7)
                case .stale: Circle().fill(Theme.attention).frame(width: 7, height: 7)
                default: EmptyView()
                }
            }
            Text(connector.plan.isEmpty ? connector.blurb : connector.plan).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(3)
            Group {
                if let last { Text("Last used \(RelativeTime.describe(last))") }
                else if case .stale = state { Text("Points at an old copy of the app. Reconnect.") }
                else if state == .connected { Text("Connected; not used yet") }
                else if !installed && connector.id != "other" { Text("Not installed") }
            }.font(.stSmall).foregroundStyle(state == .connected || last != nil ? Theme.textSecondary : Theme.textTertiary)
            HStack(spacing: 10) {
                if state == .connected || last != nil {
                    if !connector.bundleIds.isEmpty { Button("Open") { ai.open(connector) } }
                    if case .jsonFile = connector.method { Button("Disconnect") { act { try ai.disconnect(connector); return "Disconnected." } } }
                    if ai.handoffApp?.id != connector.id && !connector.bundleIds.isEmpty {
                        Button("Use for handoffs") { model.store.setSetting("ai_handoff_app", connector.id); model.refresh() }
                    }
                } else if installed || connector.method == .manual {
                    Button(working ? "Connecting…" : (state == .notConnected || state == .unknown ? "Connect" : "Reconnect")) { connect() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(working)
                }
                Button("Copy setup") { ai.copy(connector.snippet(ai.launch)); model.show("Copied \(connector.name) setup.") }
            }
            .buttonStyle(.borderless).font(.stSmall)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.fillSubtle))
    }

    func connect() {
        working = true
        Task {
            do { model.show(try await model.ai.connect(connector)) } catch { model.fail(error) }
            working = false
            model.refresh()
        }
    }

    func act(_ f: () throws -> String) {
        do { model.show(try f()) } catch { model.fail(error) }
        model.refresh()
    }
}

// MARK: Usage, privacy, chats

private struct UsagePanel: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let s = model.ai.settings
        let spent = model.store.aiSpendThisMonth()
        Panel {
            SectionHeader(title: "Usage and limits")
            HStack {
                Text(String(format: "Paid AI this month: $%.2f of $%.2f", spent, s.monthlyCapUSD)).font(.stBody)
                Spacer()
                Stepper("", value: Binding(get: { s.monthlyCapUSD }, set: { s.monthlyCapUSD = max(0, $0); model.refresh() }), in: 0...200, step: 1).labelsHidden()
            }
            Text("Paid engines pause for the month at this limit. Free, local and Apple engines are never limited by it. One task stops after \(s.perJobTokenCap / 1000)k tokens.")
                .font(.stSmall).foregroundStyle(Theme.textTertiary)
            let today = model.ai.providers.compactMap { d -> String? in
                let n = model.store.aiRequestsToday(provider: d.id)
                return n > 0 ? "\(d.name): \(n) request\(n == 1 ? "" : "s")" + (d.id == Catalog.openRouter.id ? " (free models allow about 50 a day)" : "") : nil
            }
            if !today.isEmpty { Text("Today: " + today.joined(separator: " · ")).font(.stSmall).foregroundStyle(Theme.textSecondary) }
            let week = model.store.aiTokens(provider: EngineRef.claudeCode.providerId, since: Date().addingTimeInterval(-7 * 86_400))
            if week.tokens > 0 {
                Text("Claude Code (your plan), last 7 days: \(JobRow.tokens(week.tokens)) tokens over \(week.jobs) task\(week.jobs == 1 ? "" : "s").")
                    .font(.stSmall).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct PrivacyPanel: View {
    @Environment(AppModel.self) var model
    @Binding var consentFor: ProviderDescriptor?

    var body: some View {
        let s = model.ai.settings
        Panel {
            SectionHeader(title: "Privacy")
            Text("Course material goes only to the engine or app you choose for a task. On-device engines send nothing. Grades are never sent to an AI.")
                .font(.stSmall).foregroundStyle(Theme.textSecondary)
            let agreed = Catalog.all.filter { s.consent($0.id) != nil }
            ForEach(agreed) { d in
                HStack {
                    Text("\(d.name): agreed \(s.consent(d.id).map { RelativeTime.describe($0) } ?? "")").font(.stSmall)
                    if s.trainingAllowed(d.id) { Chip(text: "training allowed", urgent: true) }
                    Spacer()
                    Button("Change") { consentFor = d }.buttonStyle(.borderless).font(.stSmall)
                    Button("Withdraw") { s.setConsent(d.id, false); model.refresh() }.buttonStyle(.borderless).font(.stSmall)
                }
            }
            HStack {
                Text("Keep chats").font(.stSmall)
                Picker("", selection: Binding(get: { s.chatRetentionDays }, set: { model.store.setSetting("ai_chat_retention_days", String($0)); model.refresh() })) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365); Text("Forever").tag(0)
                }.labelsHidden().frame(width: 120)
                Spacer()
                Text("Region for free-tier rules").font(.stSmall)
                TextField("CH", text: Binding(get: { s.region }, set: { s.region = String($0.uppercased().prefix(2)); model.refresh() }))
                    .textFieldStyle(.roundedBorder).frame(width: 44)
            }
        }
    }
}

private struct ChatsPanel: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let chats = model.store.chats(limit: 8)
        Panel {
            HStack {
                SectionHeader(title: "Chats")
                Spacer()
                Button("New chat") { model.newChat() }.buttonStyle(QuietButtonStyle()).disabled(model.ai.engineOptions().allSatisfy(\.ref.isCLI))
            }
            if chats.isEmpty { Text("Study chats appear here. They stay on this Mac.").font(.stSmall).foregroundStyle(Theme.textTertiary) }
            ForEach(chats) { c in
                HStack {
                    Button(c.title) { model.openChat(chat: c.id) }.buttonStyle(.borderless).font(.stSmall).lineLimit(1)
                    Spacer()
                    Text(RelativeTime.describe(c.updatedAt)).font(.stSmall).foregroundStyle(Theme.textTertiary)
                    Button { model.store.deleteChat(c.id); model.refresh() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
                }
            }
        }
    }
}
