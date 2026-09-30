import Foundation
import AppKit
import StudyCore

/// Runs Claude jobs. Every Claude button enqueues a job here; the label never changes with run mode.
/// Automatic mode works through the queue one job at a time with Claude Code. Desktop mode (and every
/// conversational task) copies the prompt with its job id and opens Claude Desktop; MCP writes tagged with the
/// id move the job to Waiting and then Done.
@MainActor
@Observable
final class ClaudeJobRunner {
    unowned let model: AppModel
    private var process: Process?
    private(set) var runningJobId: Int?

    init(model: AppModel) {
        self.model = model
        model.store.failInterruptedJobs()
        migrateRunMode()
    }

    private var store: StudyStore { model.store }

    // MARK: Run mode

    /// Connections › Claude: Automatic runs Claude Code in the background when it's found; Claude Desktop copies the prompt.
    var runMode: JobMode {
        get { JobMode(rawValue: store.setting("claude_run_mode") ?? "") ?? .automatic }
        set { store.setSetting("claude_run_mode", newValue.rawValue); model.refresh() }
    }

    /// Where this task will actually run.
    func mode(for task: ClaudeTask) -> JobMode {
        task.conversational || runMode == .desktop || model.claude.findCLI() == nil ? .desktop : .automatic
    }

    private func migrateRunMode() {
        guard store.setting("claude_run_mode") == nil, store.setting("use_claude_code") != nil else { return }
        store.setSetting("claude_run_mode", store.boolSetting("use_claude_code", default: true) ? "automatic" : "desktop")
    }

    // MARK: Starting jobs

    func run(_ task: ClaudeTask, material id: Int) {
        var args = ["material_id": "\(id)"]
        if task == .quiz { args = ["scope": "material", "id": "\(id)", "count": "8"] }
        run(task, args: args, objectKind: "material", objectId: id)
    }

    func run(_ task: ClaudeTask, assignment id: Int) { run(task, args: ["assignment_id": "\(id)"], objectKind: "assignment", objectId: id) }
    func run(_ task: ClaudeTask, concept id: Int) { run(task, args: ["concept_id": "\(id)"], objectKind: "concept", objectId: id) }

    func run(_ task: ClaudeTask, args: [String: String] = [:], objectKind: String? = nil, objectId: Int? = nil) {
        if let existing = store.activeJob(task, objectKind: objectKind, objectId: objectId) {
            if existing.mode == .desktop { handOff(existing.id) } else {
                model.show("\(existing.label) is already \(existing.state == .queued ? "queued" : "running").", link: ("View", .activity(jobId: existing.id)))
            }
            return
        }
        let mode = mode(for: task)
        let label = [task.activity, objectTitle(objectKind, objectId)].compactMap { $0 }.joined(separator: " ")
        do {
            let id = try store.enqueueJob(task, args: args, objectKind: objectKind, objectId: objectId, label: label, mode: mode)
            model.refresh()
            if mode == .desktop {
                handOff(id)
            } else {
                let ahead = store.activeJobs().filter { $0.mode == .automatic && $0.id != id }.count
                model.show(ahead == 0 ? "\(task.label): started." : "\(task.label): queued behind \(ahead) job\(ahead == 1 ? "" : "s").",
                           link: ("View", .activity(jobId: id)))
                pump()
            }
        } catch { model.fail(error) }
    }

    /// Copies the prompt (with its job id) and opens Claude Desktop.
    func handOff(_ id: Int) {
        guard let job = store.job(id) else { return }
        do {
            var args = job.args
            args["job_id"] = "\(id)"
            let text = try Prompts.render(job.task.prompt, args: args, store: store)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if job.state == .queued { try store.setJobState(id, .handedOff) }
            model.openClaude()
            model.refresh()
            model.show("Prompt copied. Paste it into Claude Desktop; the job finishes when Claude saves its results.",
                       link: ("View", .activity(jobId: id)))
        } catch { model.fail(error) }
    }

    /// Starts the next queued background job if none is running.
    func pump() {
        guard runningJobId == nil, let job = store.nextQueuedJob() else { return }
        guard let cli = model.claude.findCLI() else {
            // Claude Code went away: hand the job to Desktop instead.
            _ = try? store.db.execute("UPDATE claude_jobs SET mode = 'desktop' WHERE id = ?", [job.id])
            handOff(job.id)
            return
        }
        var args = job.args
        args["job_id"] = "\(job.id)"
        guard let prompt = try? Prompts.render(job.task.prompt, args: args, store: store) else {
            try? store.setJobState(job.id, .failed, error: "The prompt could not be built.")
            return pump()
        }
        runningJobId = job.id
        try? store.setJobState(job.id, .running)
        model.refresh()
        Task {
            let outcome = await model.claude.runHeadless(cli: cli, prompt: prompt, store: store) { [weak self] p in
                DispatchQueue.main.async { self?.process = p }
            }
            finish(job.id, outcome)
        }
    }

    private func finish(_ id: Int, _ outcome: Result<String, Error>) {
        process = nil
        runningJobId = nil
        let job = store.job(id)
        if job?.state == .canceled { model.refresh(); pump(); return }
        switch outcome {
        case .success(let reply):
            let summary = job?.resultSummary ?? reply.split(separator: "\n").first.map { String($0.prefix(160)) }
            try? store.setJobState(id, .done, summary: summary)
            model.show("\(job?.task.label ?? "Claude"): done. \(summary ?? "")", link: resultLink(id).map { ("Open", $0) })
        case .failure(let e):
            try? store.setJobState(id, .failed, error: e.localizedDescription)
            model.show("Claude could not finish: \(e.localizedDescription)", error: true, link: ("View", .activity(jobId: id)))
        }
        model.refresh()
        pump()
    }

    // MARK: Job actions

    func cancel(_ id: Int) {
        try? store.setJobState(id, .canceled)
        if runningJobId == id { process?.terminate() }
        model.refresh()
    }

    func markDone(_ id: Int) {
        try? store.setJobState(id, .done)
        model.refresh()
    }

    func retry(_ id: Int) {
        guard let job = store.job(id) else { return }
        run(job.task, args: job.args, objectKind: job.objectKind, objectId: job.objectId)
    }

    /// Where a job's results live.
    func resultLink(_ id: Int) -> Route? {
        guard let job = store.job(id) else { return nil }
        switch job.task {
        case .weeklyPlan: return .calendar(.week, nil)
        case .extractDeadlines: return .inbox(.deadlines)
        default: break
        }
        switch job.objectKind {
        case "material": return job.objectId.map { .material($0) }
        case "assignment": return job.objectId.map { .assignment($0) }
        case "concept":
            guard let cid = job.objectId, let course = try? store.db.first("SELECT course_id FROM concepts WHERE id = ?", [cid]) else { return nil }
            return .course(course.i("course_id"), .concepts)
        default: return nil
        }
    }

    /// Processes filed lectures in the background as they arrive (Connections › Claude).
    func autoProcessReady() {
        guard mode(for: .process) == .automatic else { return }
        for m in store.unprocessedMaterials() where m.role == .lecture && store.activeJob(.process, objectKind: "material", objectId: m.id) == nil {
            run(.process, material: m.id)
        }
    }

    var isRunning: Bool { runningJobId != nil }

    private func objectTitle(_ kind: String?, _ id: Int?) -> String? {
        guard let kind, let id else { return nil }
        switch kind {
        case "material": return store.material(id)?.title
        case "assignment": return store.assignment(id)?.title
        case "concept": return (try? store.db.scalarString("SELECT name FROM concepts WHERE id = ?", [id])) ?? nil
        default: return nil
        }
    }
}
