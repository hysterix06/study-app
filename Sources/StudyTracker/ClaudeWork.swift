import SwiftUI
import StudyCore

/// What the book writer is up to, in words.
enum ClaudeState: Equatable {
    /// No engine chosen.
    case off
    case paused(until: Date, reason: String?)
    case writing(BookJob, since: Date)
    case waitingForFiles(Int)
    case done(Int)
    case idle
}

extension AppModel {
    var claudeState: ClaudeState {
        let _ = revision
        guard engineChoice != nil else { return .off }
        if let until = books.pausedUntil, until > Date() { return .paused(until: until, reason: books.pausedReason) }
        if let job = books.job { return .writing(job, since: books.startedAt ?? Date()) }
        let totals = store.chapterTotals()
        let planned = courses.allSatisfy { $0.tocStatus == "ready" || $0.isCourse == false }
        if planned, totals.all > 0, totals.ready == totals.all { return .done(totals.all) }
        let waiting = store.chaptersWaitingForFiles()
        return waiting > 0 ? .waitingForFiles(waiting) : .idle
    }

    /// "HR Diversity · 4. Inclusive Recruitment", or "Planning the book for Spanish 2".
    func describe(_ job: BookJob) -> String {
        switch job {
        case .toc(let c): return "Planning the book for \(course(c)?.title ?? "a course")"
        case .chapter(let id):
            guard let ch = store.chapter(id) else { return "A chapter" }
            return "\(course(ch.courseId)?.title ?? "") · \(ch.position). \(ch.title)"
        }
    }

    var engineLabel: String {
        let models = engineChoice == .anthropic ? AnthropicProvider.models : ClaudeCodeProvider.models
        let name = models.first { $0.id == model }?.name.replacingOccurrences(of: " (recommended)", with: "") ?? model
        return (engineChoice == .anthropic ? "Anthropic API" : "Claude Code") + " · " + name
    }
}

/// One line on Home saying what Claude is doing. Clicking it shows the whole picture.
struct ClaudeStrip: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let state = model.claudeState
        if state != .off {
            Button { model.showingWork = true } label: {
                HStack(spacing: 10) {
                    ClaudeStateLine(state: state)
                    Spacer(minLength: 12)
                    let totals = model.store.chapterTotals()
                    if totals.all > 0 { Text("\(totals.ready) of \(totals.all) chapters").monospacedDigit().foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.45)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("What Claude has written, is writing and will write next")
        } else if model.engineDeclined {
            Text("Books aren't being written. Choose Claude in Settings › Books to start.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// "Writing HR Diversity · 4. Inclusive Recruitment · 2 min", "Paused until 19:00", "All 83 chapters are written."
struct ClaudeStateLine: View {
    @Environment(AppModel.self) var model
    let state: ClaudeState

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .writing(let job, let since):
                ProgressView().controlSize(.small)
                Text("Writing").foregroundStyle(.secondary)
                Text(model.describe(job)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text("· " + Self.elapsed(since, ctx.date)).foregroundStyle(.secondary)
                }
            case .paused(let until, let reason):
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("Paused until \(Format.time(until))")
                if let reason { Text(reason).foregroundStyle(.secondary).lineLimit(1) }
            case .waitingForFiles(let n):
                Image(systemName: "hourglass").foregroundStyle(.secondary)
                Text("Waiting for Moodle to finish reading course files (\(n) chapter\(n == 1 ? "" : "s") need them)").lineLimit(1)
            case .done(let n):
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("All \(n) chapters are written.")
            case .idle:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Nothing to write right now.")
            case .off:
                Text("Books aren't being written.")
            }
        }
    }

    static func elapsed(_ since: Date, _ now: Date) -> String {
        let m = Int(now.timeIntervalSince(since) / 60)
        return m < 1 ? "just started" : "\(m) min"
    }
}

/// Everything Claude is doing for the books: now, next, recently written, anything that failed, and each book's progress.
struct ClaudeWorkView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss
    var openBook: (Int) -> Void = { _ in }
    var openChapter: (ChapterRoute) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude's work").font(.serif(24, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Claude writes your books one chapter at a time, this week's chapters first. \(model.engineLabel).")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            ScrollView {
                ClaudeWorkContent(openBook: { dismiss(); openBook($0) }, openChapter: { dismiss(); openChapter($0) })
                    .padding(.vertical, 20)
            }
        }
        .padding(24)
        .frame(width: 620, height: 640)
    }
}

struct ClaudeWorkContent: View {
    @Environment(AppModel.self) var model
    var openBook: (Int) -> Void = { _ in }
    var openChapter: (ChapterRoute) -> Void = { _ in }

    var body: some View {
        let _ = model.revision
        let state = model.claudeState
        let current: BookJob? = if case .writing(let job, _) = state { job } else { nil }
        let next = model.store.upcomingJobs(limit: 6, excluding: current)
        let recent = model.store.recentChapters(limit: 5)
        let failed = model.courses.flatMap { c in model.store.chapters(courseId: c.id).filter { $0.status == "failed" } }
                VStack(alignment: .leading, spacing: 26) {
                    group("Now") { ClaudeStateLine(state: state) }
                    if !next.isEmpty {
                        group("Up next") {
                            ForEach(next, id: \.self) { job in
                                HStack {
                                    Text(model.describe(job)).lineLimit(1)
                                    Spacer()
                                    Text(when(job)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !recent.isEmpty {
                        group("Written recently") {
                            ForEach(recent) { ch in
                                Button { openChapter(ChapterRoute(courseId: ch.courseId, chapterId: ch.id)) } label: {
                                    HStack {
                                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                                        Text(model.describe(.chapter(id: ch.id))).lineLimit(1)
                                        Spacer()
                                        if let at = ch.generatedAt {
                                            Text(Format.relative.localizedString(for: at, relativeTo: Date())).foregroundStyle(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !failed.isEmpty {
                        group("Couldn't write") {
                            ForEach(failed) { ch in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.describe(.chapter(id: ch.id))).lineLimit(1)
                                        if let e = ch.error { Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                    Spacer()
                                    Button("Try again") { model.retry(.chapter(id: ch.id)) }
                                }
                            }
                        }
                    }
                    group("Books") {
                        ForEach(model.courses) { c in
                            let chs = model.store.chapters(courseId: c.id)
                            Button { openBook(c.id) } label: {
                                HStack(spacing: 12) {
                                    Text(c.title).lineLimit(1).frame(width: 230, alignment: .leading)
                                    ProgressView(value: Double(chs.filter(\.isReady).count), total: Double(max(chs.count, 1)))
                                        .tint(Color.course(c.color))
                                    Text(chs.isEmpty ? (c.tocStatus == "writing" ? "planning" : "not planned") : "\(chs.filter(\.isReady).count) of \(chs.count)")
                                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .font(.callout)
    }

    func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
    }

    /// "this week", "next week", "week 9", or "contents".
    func when(_ job: BookJob) -> String {
        guard case .chapter(let id) = job, let ch = model.store.chapter(id) else { return "contents" }
        guard let week = ch.week, let now = model.store.currentWeek() else { return "" }
        return week == now ? "this week" : week == now + 1 ? "next week" : "week \(week)"
    }
}
