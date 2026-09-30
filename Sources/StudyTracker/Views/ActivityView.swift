import SwiftUI
import StudyCore

/// The one button for a Claude task. The label is the same in both run modes; a small glyph after it shows whether
/// the task runs in the background (Claude Code) or in Claude Desktop.
struct ClaudeButton: View {
    @Environment(AppModel.self) var model
    var task: ClaudeTask
    var action: () -> Void

    var body: some View {
        let mode = model.jobs.mode(for: task)
        Button(action: action) {
            HStack(spacing: 5) {
                Text(task.label)
                Image(systemName: mode == .automatic ? "gearshape.2" : "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .help(mode == .automatic ? "Runs in the background with Claude Code" : "Copies the prompt and opens Claude Desktop")
    }
}

/// Toolbar button: a spinner while a job runs, a badge when a job is waiting on the student.
struct ActivityToolbarButton: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var model = model
        let _ = model.revision
        let waiting = model.store.jobsNeedingAttention().count
        Button { model.go(.activity(jobId: nil)) } label: {
            ZStack(alignment: .topTrailing) {
                if model.jobs.isRunning {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "sparkles")
                }
                if waiting > 0 {
                    Text("\(waiting)").font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.attention)).offset(x: 8, y: -6)
                }
            }
        }
        .help("Claude activity")
        .accessibilityLabel(waiting > 0 ? "Claude activity, \(waiting) waiting on you" : "Claude activity")
        .popover(isPresented: $model.showActivity, arrowEdge: .bottom) {
            ActivityList(limit: 12, highlight: model.activityJobId)
                .padding(14).frame(width: 440)
                .themed()
        }
    }
}

/// Claude's jobs, newest first: what it did, is doing, or is waiting on.
struct ActivityList: View {
    @Environment(AppModel.self) var model
    var limit = 50
    var highlight: Int? = nil

    var body: some View {
        let _ = model.revision
        let jobs = model.store.jobs(limit: limit)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude activity").font(.stBodyStrong)
                Spacer()
                if limit < 50 {
                    Button("Full history") { model.showActivity = false; model.go(.connections(.claude)) }
                        .buttonStyle(.borderless).font(.stSmall)
                }
            }
            if jobs.isEmpty {
                Text("Nothing yet. Claude's work shows up here: what it did, what it's doing, and what it's waiting on.")
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
                Text(job.mode == .automatic ? "Claude Code" : "Claude Desktop").font(.stSmall).foregroundStyle(Theme.textTertiary)
                if let line = job.state == .failed ? job.error : job.resultSummary {
                    Text(line).font(.stSmall).foregroundStyle(job.state == .failed ? Theme.attention : Theme.textSecondary).lineLimit(2)
                }
            }
            HStack(spacing: 10) {
                if job.state == .done, let r = model.jobs.resultLink(job.id) {
                    Button("Open result") { model.showActivity = false; model.go(r) }
                }
                if job.mode == .desktop && job.state.isActive {
                    Button("Copy prompt again") { model.jobs.handOff(job.id) }
                    Button("Mark done") { model.jobs.markDone(job.id) }
                }
                if job.state == .failed || job.state == .canceled { Button("Retry") { model.jobs.retry(job.id) } }
                if job.state.isActive { Button("Cancel") { model.jobs.cancel(job.id) } }
            }
            .buttonStyle(.borderless).font(.stSmall)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.corner(7)).fill(highlighted ? Theme.attention.opacity(0.08) : Theme.fillSubtle))
    }

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
