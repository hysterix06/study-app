import SwiftUI
import AppKit
import StudyCore
import StudyAI

/// The two AI choices a student ever needs. Everyday AI is free (on this Mac first) and does the small jobs; the
/// course builder is the strong model that lays out each course. Everything else lives under Advanced.
struct AISettingsSimple: View {
    @Environment(AppModel.self) var model
    /// Opens the consent sheet for a provider (the Advanced panels own it).
    var askConsent: (ProviderDescriptor) -> Void
    @State private var signingIn = false

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 14) {
            everyday
            Divider()
            builder
        }
    }

    // MARK: Everyday AI

    var everyday: some View {
        let ai = model.ai
        let current = ai.engine(for: .sortFiles)
        let options = ai.engineOptions().filter { !$0.ref.isCLI }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everyday AI").font(.stBodyStrong)
                    Text(current.map { label($0) } ?? "Not set up yet")
                        .font(.stBody).foregroundStyle(current == nil ? Theme.attention : Theme.textSecondary)
                }
                Spacer()
                Menu("Change") {
                    Button { set(everyday: nil) } label: { check("Automatic: free, on this Mac first", ai.settings.everyday == nil) }
                    if !options.isEmpty { Divider() }
                    ForEach(options) { o in
                        Button { set(everyday: o.ref) } label: { check(o.title + (o.free ? " · free" : ""), ai.settings.everyday?.providerId == o.ref.providerId) }
                    }
                }.fixedSize()
            }
            Text(ai.candidates(for: .checkAnswer).isEmpty
                 ? "Sorts your files and reads practice problems and syllabi. Sign in with OpenRouter (free) to also get answer checks and a tutor: the model on this Mac isn't reliable enough to grade."
                 : "Sorts your files, reads practice problems and syllabi, checks your answers and tutors you.")
                .font(.stSmall).foregroundStyle(Theme.textTertiary)
            if current == nil { setUpEveryday }
        }
    }

    /// Nothing can run everyday work: the two free ways to fix that, right here.
    @ViewBuilder var setUpEveryday: some View {
        let apple = AppleProviders.availability(Catalog.appleOnDevice)
        VStack(alignment: .leading, spacing: 6) {
            if !apple.available {
                Text(apple.reason ?? "Apple Intelligence isn't available on this Mac.").font(.stSmall).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 8) {
                if !apple.available {
                    Button("Open Apple Intelligence settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }.buttonStyle(QuietButtonStyle())
                }
                Button(signingIn ? "Waiting for OpenRouter…" : "Sign in with OpenRouter (free)") { signInOpenRouter() }
                    .buttonStyle(QuietButtonStyle()).disabled(signingIn)
            }
            Text("Your files keep sorting by their names in the meantime; nothing waits on this.").font(.stSmall).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Course builder

    var builder: some View {
        let ai = model.ai
        let choice = ai.settings.builder
        let cli = ai.claudeCLI() != nil && ai.mcpBinary != nil
        let strong = ai.readyEngines().filter(\.strong)
        let current = ai.settings.builderChosen ? builderEngine(choice: choice, cli: cli, strong: strong) : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Course builder").font(.stBodyStrong)
                    Text(current ?? "Free AI builds a basic version").font(.stBody).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Menu("Change") {
                    Button { set(builder: .automatic) } label: { check("Automatic: Claude when it's here", ai.settings.builderChosen && choice == .automatic) }
                    if cli { Button { set(builder: .claudeCode) } label: { check("Claude Code · uses your Claude plan", choice == .claudeCode) } }
                    ForEach(strong, id: \.ref) { c in
                        Button { set(builder: .engine(c.ref)) } label: { check(c.ref.displayName + " · paid per use", choice == .engine(c.ref)) }
                    }
                    Divider()
                    Button { set(builder: .basicOnly) } label: { check("Free AI only (basic version)", !ai.settings.builderChosen) }
                }.fixedSize()
            }
            Text("Lays out each course the best way to learn it, and writes its notebook guide and lessons.")
                .font(.stSmall).foregroundStyle(Theme.textTertiary)
            if current == nil {
                if cli || !strong.isEmpty {
                    Button(cli ? "Use Claude Code to build your courses" : "Use \(strong[0].ref.displayName) to build your courses") { set(builder: .automatic) }
                        .buttonStyle(QuietButtonStyle())
                    Text(cli ? "Uses your Claude plan: a few minutes per course, in the background." : "Paid per use, within your monthly limit.")
                        .font(.stSmall).foregroundStyle(Theme.textTertiary)
                } else {
                    Text(ai.edition.isSandboxed
                         ? "For a fuller course, add an Anthropic API key under Advanced, or use Copy for Claude.ai when a course is built."
                         : "For a fuller course, install Claude Code (it uses your Claude plan), or add an Anthropic API key under Advanced.")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                    if !ai.edition.isSandboxed {
                        Button("Look for Claude Code again") { ai.resetCLICache(); model.refresh() }.buttonStyle(.borderless).font(.stSmall)
                    }
                }
            } else if let until = model.store.builderPausedUntil, until > Date() {
                Text("Paused until \(Formatters.dayTime(until, tz: model.tz)): \(model.store.setting("ai_builder_paused_reason") ?? "the course builder couldn't run"). Free AI keeps building basic versions.")
                    .font(.stSmall).foregroundStyle(Theme.textSecondary)
                Button("Try again now") { model.store.builderPausedUntil = nil; model.jobs.buildCourses() }.buttonStyle(.borderless).font(.stSmall)
            }
        }
    }

    /// What builds courses right now, in words, or nil when only free AI can.
    func builderEngine(choice: BuilderChoice, cli: Bool, strong: [EngineCandidate]) -> String? {
        switch choice {
        case .basicOnly: return "Free AI (basic version)"
        case .claudeCode: return cli ? "Claude Code · uses your Claude plan" : nil
        case .engine(let r): return strong.contains { $0.ref.providerId == r.providerId } ? "\(r.displayName) · paid per use" : nil
        case .automatic:
            if cli { return "Claude Code · uses your Claude plan" }
            return strong.first.map { "\($0.ref.displayName) · paid per use" }
        }
    }

    // MARK: Helpers

    func label(_ ref: EngineRef) -> String {
        let free = model.ai.readyEngines().first { $0.ref.providerId == ref.providerId }?.free ?? false
        return ref.displayName + (free ? " · free" : " · paid")
    }

    @ViewBuilder func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    func set(everyday ref: EngineRef?) {
        model.ai.settings.everyday = ref
        if let ref, let m = ref.model { model.ai.settings.setModel(m, forProvider: ref.providerId) }
        model.refresh()
        model.jobs.readNewFiles()
    }

    func set(builder choice: BuilderChoice) {
        model.ai.settings.builder = choice
        if choice != .basicOnly { model.store.builderPausedUntil = nil }
        model.refresh()
        model.jobs.buildCourses()
    }

    func signInOpenRouter() {
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                try await model.ai.signInWithOpenRouter()
                if model.ai.settings.needsConsent(Catalog.openRouter) { askConsent(Catalog.openRouter) }
                model.refresh()
                model.jobs.readNewFiles()
            } catch { model.fail(error) }
        }
    }
}
