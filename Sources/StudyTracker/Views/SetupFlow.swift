import SwiftUI
import AppKit
import StudyCore
import StudyAI
import UniformTypeIdentifiers

/// First launch: a full-window flow instead of an empty Today. Every step can be skipped, progress is saved, and
/// quitting midway resumes at the same step. Anything skipped shows up in Today's setup checklist.
struct SetupFlow: View {
    @Environment(AppModel.self) var model
    var step: SetupStep

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            progress.padding(.top, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(32).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider()
            footer.padding(.horizontal, 32).padding(.vertical, 14)
        }
        .background(Theme.canvas)
    }

    var progress: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases) { s in
                Capsule().fill(s == step ? Theme.textPrimary : index(s) < index(step) ? Theme.textTertiary : Theme.fillSubtle.opacity(3))
                    .frame(width: s == step ? 22 : 8, height: 8)
            }
        }
        .animation(.easeOut(duration: Theme.motionFast), value: step)
        .accessibilityLabel("Step \(index(step) + 1) of \(SetupStep.allCases.count)")
    }

    @ViewBuilder var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .moodle: MoodleStep()
        case .term: TermStep()
        case .timetable: TimetableStep()
        case .ai: AIStep()
        case .files: FilesStep()
        case .done: DoneStep()
        }
    }

    @ViewBuilder var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { model.go(.setup(previous(step))) }.buttonStyle(QuietButtonStyle())
            }
            Spacer()
            switch step {
            case .welcome:
                EmptyView()
            case .done:
                Button("Go to Today") { finishSetup(model) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            default:
                Button("Skip") { model.go(.setup(next(step))) }.buttonStyle(.borderless).foregroundStyle(Theme.textSecondary)
                Button("Continue") { model.go(.setup(next(step))) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    func index(_ s: SetupStep) -> Int { SetupStep.allCases.firstIndex(of: s) ?? 0 }

    /// Moodle usually brings the term and courses, which makes the term and timetable steps unnecessary.
    func next(_ s: SetupStep) -> SetupStep {
        var i = index(s) + 1
        while i < SetupStep.allCases.count - 1 {
            let candidate = SetupStep.allCases[i]
            if candidate == .term && model.store.currentTerm() != nil { i += 1; continue }
            if candidate == .timetable && model.moodle.isConnected && !model.store.courses().isEmpty { i += 1; continue }
            break
        }
        return SetupStep.allCases[min(i, SetupStep.allCases.count - 1)]
    }

    func previous(_ s: SetupStep) -> SetupStep { SetupStep.allCases[max(index(s) - 1, 0)] }
}

@MainActor
func finishSetup(_ model: AppModel) {
    model.store.setBool("setup_completed", true)
    model.store.setSetting("setup_step", nil)
    model.go(.today, replace: true)
    model.refresh()
}

private struct StepHeader: View {
    var title: String
    var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.stTitle)
            Text(detail).font(.stBody).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    @Environment(AppModel.self) var model
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
            StepHeader(title: "Welcome to Study Tracker",
                       detail: "It keeps your classes, deadlines and lectures in one place, and tells you the single most useful thing to do next.")
            HStack {
                Button("Get started") { model.go(.setup(.moodle)) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                Button(loading ? "Loading…" : "Explore with sample data") {
                    loading = true
                    do {
                        try SampleData.load(model.store)
                        finishSetup(model)
                        model.show("Sample term, courses, classes and a lecture were added. Remove them any time in Settings › Data and export.")
                    } catch { model.fail(error) }
                    loading = false
                }.buttonStyle(QuietButtonStyle())
            }
        }
    }
}

private struct MoodleStep: View {
    @Environment(AppModel.self) var model
    @State private var creating = false
    var body: some View {
        let unlinked = MoodleSync.unlinkedCurrentCourses(store: model.store)
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Your school", detail: "Connect Moodle and your courses, deadlines, grades and files come in on their own.")
            if model.moodle.isConnected && !unlinked.isEmpty {
                Panel {
                    Text("Moodle lists \(unlinked.count) current course\(unlinked.count == 1 ? "" : "s").").font(.stBodyStrong)
                    Text(unlinked.map { $0.shortname.isEmpty ? $0.fullname : $0.shortname }.joined(separator: " · ")).font(.stSmall).foregroundStyle(Theme.textSecondary)
                    Button(creating ? "Creating…" : "Create \(model.store.currentTerm() == nil ? "the term and " : "")\(unlinked.count == 1 ? "this course" : "these courses")") {
                        creating = true
                        do {
                            let r = try MoodleSync.createCoursesAndTerm(store: model.store)
                            model.refresh()
                            model.show("Added \(r.courses) course\(r.courses == 1 ? "" : "s")\(r.termCreated ? " and the current term" : "") from Moodle.")
                            Task { await model.moodle.sync(silent: true); creating = false }
                        } catch { model.fail(error); creating = false }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(creating)
                }
            }
            MoodleSettings()
        }
    }
}

private struct TermStep: View {
    @Environment(AppModel.self) var model
    @State private var name = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(105 * 86_400)
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "This term", detail: "Classes only appear inside a term. Add breaks later in Settings › Terms and breaks.")
            if let t = model.store.currentTerm() {
                Panel {
                    Text(t.name).font(.stBodyStrong)
                    Text("\(t.startDate.string) → \(t.endDate.string)").font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
            } else {
                Form {
                    TextField("Name", text: $name, prompt: Text("Fall 2026"))
                    DatePicker("Starts", selection: $start, displayedComponents: .date)
                    DatePicker("Ends", selection: $end, displayedComponents: .date)
                }.formStyle(.grouped)
                Button("Save term") {
                    model.run("Saved \(name).") {
                        _ = try model.store.saveTerm(Term(name: name, startDate: LocalDate(start, tz: .current), endDate: LocalDate(end, tz: .current), isCurrent: true))
                        return nil
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(name.isEmpty)
            }
        }
    }
}

private struct TimetableStep: View {
    @Environment(AppModel.self) var model
    @State private var addingFeed = false
    var body: some View {
        let sources = model.store.calendarSources()
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Your timetable",
                       detail: "Import an .ics file from Outlook or your school, or subscribe to a calendar link. You'll see what it adds before anything changes.")
            HStack {
                Button("Import .ics file…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "ics")].compactMap { $0 }
                    if p.runModal() == .OK, let u = p.url { model.previewICS(fileURL: u) }
                }.buttonStyle(PrimaryButtonStyle())
                Button("Subscribe to a calendar link…") { addingFeed = true }.buttonStyle(QuietButtonStyle())
            }
            ForEach(sources) { s in
                Label("\(s.name) · \(s.lastStatus ?? "added")", systemImage: "checkmark.circle.fill").font(.stBody).foregroundStyle(Theme.success)
            }
        }
        .sheet(isPresented: $addingFeed) { FeedSheet() }
    }
}

private struct AIStep: View {
    @Environment(AppModel.self) var model
    @State private var consentFor: ProviderDescriptor?
    @State private var signingIn = false

    var body: some View {
        let _ = model.revision
        let ai = model.ai
        let apple = ai.providers.filter(\.isApple)
        let apps = Connectors.all.filter { ai.isInstalled($0) && $0.id != "other" }
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "AI", detail: "Optional. AI turns lectures into concepts, questions and Cornell sheets, and studies with you. Start free; change it any time in Connections › AI.")
            Panel {
                SectionHeader(title: "Free, built in")
                ForEach(apple) { d in
                    let status = ai.status(d)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.stBodyStrong)
                            Text(status == .ready || status == .needsConsent ? d.dataUse.label : (status.unavailableReason ?? "")).font(.stSmall).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if status == .ready {
                            let chosen = ai.settings.defaultEngine?.providerId == d.id
                            Button(chosen ? "Chosen" : "Use this") { ai.settings.defaultEngine = EngineRef(d.id); model.refresh() }
                                .buttonStyle(PrimaryButtonStyle()).disabled(chosen)
                        } else if status == .needsConsent {
                            Button("Turn on") { consentFor = d }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free models online (OpenRouter)").font(.stBodyStrong)
                        Text("Sign in once for free models such as GPT-OSS, Kimi and Qwen (about 50 requests a day).").font(.stSmall).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if ai.status(Catalog.openRouter) == .ready {
                        Label("Ready", systemImage: "checkmark.circle.fill").font(.stSmall).foregroundStyle(Theme.success)
                    } else if ai.hasKey(Catalog.openRouter) {
                        Button("Turn on") { consentFor = Catalog.openRouter }.buttonStyle(QuietButtonStyle())
                    } else {
                        Button(signingIn ? "Waiting for browser…" : "Sign in") { signIn() }.buttonStyle(QuietButtonStyle()).disabled(signingIn)
                    }
                }
            }
            if !apps.isEmpty {
                Panel {
                    SectionHeader(title: "AI apps on this Mac")
                    ForEach(apps.prefix(5)) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.stBodyStrong)
                                Text(c.plan).font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            }
                            Spacer()
                            if ai.state(c) == .connected { Label("Connected", systemImage: "checkmark.circle.fill").font(.stSmall).foregroundStyle(Theme.success) }
                            else { Button("Connect") { connect(c) }.buttonStyle(QuietButtonStyle()) }
                        }
                    }
                }
            }
            Text("Groq, Gemini, Mistral, models on your own computer, Claude or OpenAI with your own key, and more are in Connections › AI.")
                .font(.stSmall).foregroundStyle(Theme.textTertiary)
        }
        .sheet(item: $consentFor) { d in ConsentSheet(provider: d) }
    }

    func signIn() {
        signingIn = true
        Task {
            do {
                try await model.ai.signInWithOpenRouter()
                if model.ai.settings.needsConsent(Catalog.openRouter) { consentFor = Catalog.openRouter }
            } catch { model.fail(error) }
            signingIn = false
            model.refresh()
        }
    }

    func connect(_ c: AIAppConnector) {
        Task {
            do { model.show(try await model.ai.connect(c)) } catch { model.fail(error) }
            model.refresh()
        }
    }
}

extension AIService.ProviderStatus {
    var unavailableReason: String? { if case .unavailable(let r) = self { return r }; return nil }
}

private struct FilesStep: View {
    @Environment(AppModel.self) var model
    @State private var targeted = false
    var body: some View {
        let count = model.store.materials().count
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Your first files", detail: "Drop lecture slides or PDFs here. They go to the Inbox, where you file each one under its course.")
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 28)).foregroundStyle(Theme.textTertiary)
                Text(count == 0 ? "Drop files here" : "\(count) file\(count == 1 ? "" : "s") added").font(.stBodyStrong)
                Button("Choose files…") { model.chooseFilesToImport() }.buttonStyle(QuietButtonStyle())
            }
            .frame(maxWidth: .infinity).padding(.vertical, 36)
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(targeted ? Theme.textSecondary : Theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                loadURLs(providers) { model.importFiles($0) }
                return true
            }
        }
    }
}

private struct DoneStep: View {
    @Environment(AppModel.self) var model
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "You're set", detail: "Anything you skipped stays on Today's setup checklist and in Connections.")
            Panel {
                ForEach(SetupItem.all, id: \.title) { item in
                    let done = item.isDone(model)
                    HStack(spacing: 10) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.success : Theme.textTertiary)
                        Text(item.title).font(.stBody)
                        Spacer()
                        Text(done ? "Done" : "Skipped").font(.stSmall).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }
}

/// One setup task. Done is read from the data, so an item ticks itself off however it gets done.
struct SetupItem {
    var title: String
    var isDone: @MainActor (AppModel) -> Bool
    var open: @MainActor (AppModel) -> Void

    @MainActor static let all: [SetupItem] = [
        SetupItem(title: "Connect Moodle", isDone: { $0.moodle.isConnected }, open: { $0.go(.connections(.moodle)) }),
        SetupItem(title: "Add your timetable", isDone: { !$0.store.calendarSources().isEmpty || !$0.store.patterns().isEmpty },
                  open: { $0.go(.connections(.calendars)) }),
        SetupItem(title: "Set up AI", isDone: { $0.connectionStatus(.ai).isConnected }, open: { $0.go(.connections(.ai)) }),
        SetupItem(title: "Add your first lecture", isDone: { !$0.store.materials().isEmpty }, open: { $0.chooseFilesToImport() }),
        SetupItem(title: "Set grade targets", isDone: { m in m.store.courses().contains { $0.targetGrade != nil } },
                  open: { m in if let c = m.store.courses().first { m.go(.course(c.id, .overview)) } }),
    ]
}

/// Today (until done or hidden) and Connections (once hidden).
struct SetupChecklist: View {
    @Environment(AppModel.self) var model
    var showsHide = true

    var body: some View {
        let items = SetupItem.all
        let open = items.filter { !$0.isDone(model) }
        if !open.isEmpty {
            Panel {
                HStack {
                    SectionHeader(title: "Finish setting up · \(items.count - open.count) of \(items.count)")
                    Spacer()
                    if showsHide {
                        Button("Hide checklist") { model.store.setBool("setup_checklist_hidden", true); model.refresh() }
                            .buttonStyle(.borderless).font(.stSmall)
                    }
                }
                ForEach(open, id: \.title) { item in
                    Button { item.open(model) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
                            Text(item.title).font(.stBody)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
