import SwiftUI
import StudyCore
import StudyAI

/// AI jobs, newest first: what was done, is running, or is waiting on the student.
struct ActivityList: View {
    @Environment(AppModel.self) var model
    var limit = 50
    var highlight: Int? = nil

    var body: some View {
        let _ = model.revision
        let jobs = model.store.jobs(limit: limit)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI activity").font(.stBodyStrong)
                Spacer()
                if limit < 50 {
                    Button("Full history") { model.go(.settings(.ai)) }
                        .buttonStyle(.borderless).font(.stSmall)
                }
            }
            if jobs.isEmpty {
                Text("Nothing yet. AI work shows up here: what was done, what's running, and what's waiting on you.")
                    .font(.stSmall).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(jobs) { job in JobRow(job: job, highlighted: job.id == highlight) }
                }
            }.frame(maxHeight: limit < 50 ? 420 : .infinity)
        }
    }
}

struct JobRow: View {
    @Environment(AppModel.self) var model
    var job: ClaudeJob
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                stateIcon
                Text(job.label).font(.stBody).lineLimit(1)
                Spacer()
                Text(RelativeTime.describe(job.finishedAt ?? job.startedAt ?? job.createdAt)).font(.stSmall).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 6) {
                Chip(text: job.state.title, urgent: job.state == .failed)
                Text(Self.engineName(job)).font(.stSmall).foregroundStyle(Theme.textTertiary)
                if job.state == .running, let p = model.jobs.progressText, model.jobs.runningJobId == job.id {
                    Text(p).font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
                if let line = job.state == .failed ? job.error : job.resultSummary {
                    Text(line).font(.stSmall).foregroundStyle(job.state == .failed ? Theme.attention : Theme.textSecondary).lineLimit(2)
                }
            }
            HStack(spacing: 10) {
                if job.state == .done, let r = model.jobs.resultLink(job.id) {
                    Button("Open result") { model.go(r) }
                }
                if job.mode == .desktop && job.state.isActive {
                    Button("Copy prompt again") { model.jobs.handOff(job.id) }
                    if PastePrompts.supported.contains(job.task) { Button("Use any chatbot instead") { model.jobs.switchToPaste(job.id) } }
                    Button("Mark done") { model.jobs.markDone(job.id) }
                }
                if job.mode == .chat && job.state.isActive { Button("Open chat") { model.openChat(job: job.id) } }
                if job.mode == .paste && job.state.isActive { Button("Paste answer") { model.paste = PasteRequest(jobId: job.id) } }
                if job.state == .failed && job.mode == .automatic && PastePrompts.supported.contains(job.task) {
                    Button("Use any chatbot instead") { model.jobs.switchToPaste(job.id) }
                }
                if job.tokensIn + job.tokensOut > 0 {
                    Text("\(Self.tokens(job.tokensIn + job.tokensOut)) tokens" + (job.costUSD.map { $0 > 0 ? String(format: " · $%.3f", $0) : " · free" } ?? ""))
                        .foregroundStyle(Theme.textTertiary)
                }
                if job.state == .failed || job.state == .canceled { Button("Retry") { model.jobs.retry(job.id) } }
                if job.state.isActive { Button("Cancel") { model.jobs.cancel(job.id) } }
            }
            .buttonStyle(.borderless).font(.stSmall)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(highlighted ? Theme.attention.opacity(0.08) : Theme.fillSubtle))
    }

    static func engineName(_ job: ClaudeJob) -> String {
        switch job.mode {
        case .chat: return "Chat · " + (EngineRef(string: job.engine)?.displayName ?? "AI")
        case .paste: return "Any chatbot (copy and paste)"
        case .desktop: return job.engine.flatMap { $0.hasPrefix("app.") ? Connectors.connector(String($0.dropFirst(4)))?.name : nil } ?? "Your AI app"
        case .automatic: return EngineRef(string: job.engine)?.displayName ?? "Claude Code"
        }
    }

    static func tokens(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }

    @ViewBuilder var stateIcon: some View {
        switch job.state {
        case .running: ProgressView().controlSize(.mini)
        case .queued: Image(systemName: "clock").foregroundStyle(Theme.textTertiary)
        case .handedOff, .waiting: Image(systemName: "hourglass").foregroundStyle(Theme.attention)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
        case .canceled: Image(systemName: "xmark.circle").foregroundStyle(Theme.textTertiary)
        }
    }
}
