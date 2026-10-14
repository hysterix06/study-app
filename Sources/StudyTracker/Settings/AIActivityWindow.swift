import SwiftUI
import AppKit
import StudyCore
import StudyAI

/// The AI Activity window: what the AI is doing right now (each request and reply as it happens, with the exact prompt
/// and answer a click away), what starts next, and what it did. Any job can be paused, delayed, moved to the front or
/// canceled, and all AI can be paused for a while.
struct AIActivityWindow: View {
    static let id = "ai-activity"
    @Environment(AppModel.self) var model

    var body: some View {
        let _ = model.revision
        let _ = model.jobs.logTick
        let store = model.store
        let running = model.jobs.running.values.sorted().compactMap { store.job($0) }
        let upcoming = store.upcomingJobs()
        let withYou = store.activeJobs().filter { $0.mode != .automatic }
        let recent = store.jobs(limit: 60).filter { !$0.state.isActive }.prefix(20)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ActivityHeader()
                Panel {
                    SectionHeader(title: "Now")
                    if running.isEmpty {
                        Text(store.aiPaused() ? "Nothing is running while AI is paused." : "Nothing is running.")
                            .font(.stSmall).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(running) { job in
                        RunningJobCard(job: job)
                        if job.id != running.last?.id { Divider() }
                    }
                }
                Panel {
                    SectionHeader(title: "Up next")
                    if upcoming.isEmpty { Text("Nothing is waiting.").font(.stSmall).foregroundStyle(Theme.textSecondary) }
                    ForEach(upcoming) { job in
                        UpcomingJobRow(job: job, first: upcoming.first { $0.lane == job.lane && !$0.paused }?.id == job.id)
                        if job.id != upcoming.last?.id { Divider() }
                    }
                }
                if !withYou.isEmpty {
                    Panel {
                        SectionHeader(title: "Waiting on you")
                        ForEach(withYou) { JobRow(job: $0) }
                    }
                }
                Panel {
                    SectionHeader(title: "Recently finished")
                    if recent.isEmpty { Text("Nothing yet.").font(.stSmall).foregroundStyle(Theme.textSecondary) }
                    ForEach(Array(recent)) { JobRow(job: $0) }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}

/// Pause all AI, and the course builder's own pause after the student's Claude plan ran out.
private struct ActivityHeader: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI activity").font(.stTitle)
                    Text("Every request the AI sends and what comes back. Click Prompt or Reply to read the exact text.")
                        .font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if store.aiPaused() {
                    Button("Resume AI") { model.jobs.resumeAll() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Menu("Pause all AI") {
                        Button("For 1 hour") { model.jobs.pauseAll(until: Date().addingTimeInterval(3600)) }
                        Button("For 3 hours") { model.jobs.pauseAll(until: Date().addingTimeInterval(3 * 3600)) }
                        Button("Until tomorrow morning") { model.jobs.pauseAll(until: DelayMenu.tomorrowMorning) }
                        Divider()
                        Button("Until I resume it") { model.jobs.pauseAll(until: .distantFuture) }
                    }
                    .menuStyle(.button).buttonStyle(QuietButtonStyle()).fixedSize()
                    .help("Stops what's running now and starts nothing new. Each job picks up where the queue left it.")
                }
            }
            if let until = store.aiPausedUntil, until > Date() {
                Banner(icon: "pause.circle.fill",
                       text: "AI is paused \(AIJobRunner.until(until)). Running jobs went back to the queue; nothing new starts.")
            }
            if store.builderPaused(), let until = store.builderPausedUntil {
                Banner(icon: "hourglass",
                       text: "The course builder waits \(AIJobRunner.until(until)): \(store.setting("ai_builder_paused_reason") ?? "it failed on every engine"). Free AI writes basic versions meanwhile.",
                       action: ("Try Claude now", { model.jobs.resumeBuilder() }))
            }
        }
    }
}

private struct Banner: View {
    var icon: String
    var text: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.attention)
            Text(text).font(.stSmall).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action { Button(action.0, action: action.1).buttonStyle(QuietButtonStyle()) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(Theme.attention.opacity(0.08)))
    }
}

/// A running job: what it's on, a live clock while it waits for a reply, and its latest log lines.
private struct RunningJobCard: View {
    @Environment(AppModel.self) var model
    var job: ClaudeJob
    @State private var showLog = false

    var body: some View {
        let events = model.store.jobEvents(job.id, limit: 8)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(job.label).font(.stBodyStrong).lineLimit(2)
                Spacer()
                JobControls(job: job, running: true)
            }
            Text(details).font(.stSmall).foregroundStyle(Theme.textTertiary)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if let line = liveLine(events, now: ctx.date) {
                    Text(line).font(.stSmall).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(events) { EventLine(event: $0) }
            }
            .padding(.leading, 4)
            Button("Full log") { showLog = true }.buttonStyle(.borderless).font(.stSmall)
        }
        .sheet(isPresented: $showLog) { JobLogSheet(jobId: job.id).themedSheet() }
    }

    private var details: String {
        var parts = [JobRow.engineName(job)]
        if let started = job.startedAt { parts.append("started \(RelativeTime.describe(started))") }
        if let p = model.store.builderProgress(job.id), job.task.engineLane == .builder { parts.append("\(p.done) of \(p.of) written") }
        if job.tokensIn + job.tokensOut > 0 { parts.append("\(JobRow.tokens(job.tokensIn + job.tokensOut)) tokens so far") }
        if job.attempts > 0 { parts.append("try \(job.attempts + 1)") }
        return parts.joined(separator: " · ")
    }

    /// "Waiting for the reply to request 2 · 1:42" while a request is out.
    private func liveLine(_ events: [JobEvent], now: Date) -> String? {
        guard let last = events.last(where: { $0.kind != .progress || !$0.text.hasPrefix("Claude Code is running") }) else { return nil }
        let elapsed = JobLogger.duration(now.timeIntervalSince(last.at))
        switch last.kind {
        case .request: return "Waiting for the reply · \(elapsed)"
        case .progress: return "\(last.text) · \(elapsed)"
        default: return nil
        }
    }
}

/// A queued job: why it's waiting, and the controls to change that.
private struct UpcomingJobRow: View {
    @Environment(AppModel.self) var model
    var job: ClaudeJob
    var first: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: job.paused ? "pause.circle" : (job.notBefore.map { $0 > Date() } ?? false) ? "timer" : "clock")
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.label).font(.stBody).lineLimit(2)
                Text(reason).font(.stSmall).foregroundStyle(Theme.textTertiary).lineLimit(2)
            }
            Spacer()
            JobControls(job: job, running: false, first: first)
        }
    }

    private var reason: String {
        let store = model.store
        let lane = job.lane == "builder" ? "Course building" : "Files"
        if job.paused { return "\(lane) · paused by you" }
        if let t = job.notBefore, t > Date() {
            return "\(lane) · starts \(AIJobRunner.time(t))" + (job.attempts > 0 ? (job.error.map { " · last try: \($0)" } ?? "") : "")
        }
        if store.aiPaused() { return "\(lane) · waits while AI is paused" }
        if model.studying && job.lane == "everyday" && job.priority > 0 { return "\(lane) · waits until your session ends" }
        return "\(lane) · " + (first ? (model.jobs.running[job.lane] == nil ? "starting" : "next in line") : "waiting its turn")
    }
}

/// Pause or resume, delay, move to the front, cancel.
private struct JobControls: View {
    @Environment(AppModel.self) var model
    var job: ClaudeJob
    var running: Bool
    var first = false

    var body: some View {
        HStack(spacing: 6) {
            if !running && !first && !job.paused { Button("Run next") { model.jobs.runNext(job.id) }.help("Start it before the others in its queue.") }
            if job.paused { Button("Resume") { model.jobs.resume(job.id) } }
            else {
                Button("Pause") { model.jobs.pause(job.id) }
                    .help(running ? "Stops it now and keeps it in the queue until you resume it. The step in progress starts over."
                                  : "Keeps it in the queue until you resume it.")
            }
            DelayMenu { model.jobs.delay(job.id, until: $0) }
            Button("Cancel") { model.jobs.cancel(job.id) }.help("Stops it for good. You can retry it from Recently finished.")
        }
        .buttonStyle(.borderless).font(.stSmall)
    }
}

/// Later: in 30 minutes, an hour, three hours, or tomorrow morning.
struct DelayMenu: View {
    var action: (Date) -> Void

    static var tomorrowMorning: Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!)!
    }

    var body: some View {
        Menu("Delay") {
            Button("30 minutes") { action(Date().addingTimeInterval(30 * 60)) }
            Button("1 hour") { action(Date().addingTimeInterval(3600)) }
            Button("3 hours") { action(Date().addingTimeInterval(3 * 3600)) }
            Button("Tomorrow morning") { action(Self.tomorrowMorning) }
        }
        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
        .help("Starts it later. A running job stops now; its step starts over then.")
    }
}

/// One line of a job's log, with its full prompt or reply a click away.
struct EventLine: View {
    @Environment(AppModel.self) var model
    var event: JobEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.at.formatted(date: .omitted, time: .standard)).font(.stSmall).monospacedDigit().foregroundStyle(Theme.textTertiary)
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(event.kind == .error ? Theme.attention : Theme.textTertiary)
                .frame(width: 12)
            Text(event.text).font(.stSmall).foregroundStyle(event.kind == .error ? Theme.attention : Theme.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let file = event.file {
                let url = model.store.paths.absolute(file)
                Button(event.kind == .request ? "Prompt" : "Reply") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderless).font(.stSmall)
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
                    .help("Opens the exact text in your text editor.")
            }
        }
    }

    private var icon: String {
        switch event.kind {
        case .start: return "play.fill"
        case .request: return "arrow.up.right"
        case .reply: return "arrow.down.left"
        case .progress: return "ellipsis"
        case .error: return "exclamationmark.triangle.fill"
        case .control: return "hand.raised.fill"
        case .finish: return "flag.checkered"
        }
    }
}

/// A job's whole log.
struct JobLogSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var jobId: Int

    var body: some View {
        let _ = model.jobs.logTick
        let job = model.store.job(jobId)
        let events = model.store.jobEvents(jobId)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job?.label ?? "AI job").font(.stHeading)
                if let job {
                    Text([job.state.title, JobRow.engineName(job), job.tokensIn + job.tokensOut > 0 ? "\(JobRow.tokens(job.tokensIn + job.tokensOut)) tokens" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.stSmall).foregroundStyle(Theme.textTertiary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if events.isEmpty { Text("No log for this job. Jobs keep a log from this version on.").font(.stSmall).foregroundStyle(Theme.textSecondary) }
                    ForEach(events) { EventLine(event: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                let folder = model.store.paths.aiLog.appendingPathComponent("job-\(jobId)")
                if FileManager.default.fileExists(atPath: folder.path) {
                    Button("Show files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }.buttonStyle(QuietButtonStyle())
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }
}
