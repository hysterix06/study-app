import Foundation
import AppKit
import StudyCore
import StudyAI
import StudyMCPCore

/// Runs AI jobs. Every AI button enqueues a job here; the label never changes with the engine.
/// - Background tasks run one at a time on the chosen engine: a built-in model (as a pipeline or a tool loop) or
///   Claude Code.
/// - Conversations open in the app's chat panel when an engine can chat, otherwise in the student's AI app.
/// - With no engine at all, the prompt is copied for the student's AI app (MCP), or for any chatbot (paste back).
@MainActor
@Observable
final class AIJobRunner {
    unowned let model: AppModel
    private var process: Process?
    private var task: Task<Void, Never>?
    private(set) var runningJobId: Int?
    private(set) var progressText: String?

    init(model: AppModel) {
        self.model = model
        model.store.failInterruptedJobs()
    }

    private var store: StudyStore { model.store }
    private var ai: AIService { model.ai }

    // MARK: Where a task runs

    enum Route: Equatable {
        case engine(EngineRef)
        case chat(EngineRef)
        case handoff
        case paste
    }

    func route(for task: AITask) -> Route {
        if let ref = ai.engine(for: task) {
            if task.conversational { return ref.isCLI ? .handoff : .chat(ref) }
            return .engine(ref)
        }
        if ai.handoffApp == nil && PastePrompts.supported.contains(task) { return .paste }
        return .handoff
    }

    /// For buttons: the glyph and tooltip that say where a task will run.
    func mode(for task: AITask) -> JobMode {
        switch route(for: task) {
        case .engine: return .automatic
        case .chat: return .chat
        case .handoff: return .desktop
        case .paste: return .paste
        }
    }

    func describe(_ task: AITask) -> String {
        switch route(for: task) {
        case .engine(let r): return "Runs in the background with \(r.displayName)"
        case .chat(let r): return "Opens a chat here with \(r.displayName)"
        case .handoff: return "Copies the prompt and opens \(ai.handoffApp?.name ?? "your AI app")"
        case .paste: return "Copies a prompt for any chatbot; paste its answer back"
        }
    }

    // MARK: Starting jobs

    func run(_ task: AITask, material id: Int) {
        var args = ["material_id": "\(id)"]
        if task == .quiz { args = ["scope": "material", "id": "\(id)", "count": "8"] }
        run(task, args: args, objectKind: "material", objectId: id)
    }

    /// Study notes for a lecture processed before they existed; nothing else about it changes.
    func makeStudyNotes(material id: Int) {
        run(.process, args: ["material_id": "\(id)", "notes_only": "1"], objectKind: "material", objectId: id)
    }

    func run(_ task: AITask, assignment id: Int) { run(task, args: ["assignment_id": "\(id)"], objectKind: "assignment", objectId: id) }
    func run(_ task: AITask, concept id: Int) { run(task, args: ["concept_id": "\(id)"], objectKind: "concept", objectId: id) }

    func run(_ task: AITask, args: [String: String] = [:], objectKind: String? = nil, objectId: Int? = nil) {
        if let existing = store.activeJob(task, objectKind: objectKind, objectId: objectId) {
            switch existing.mode {
            case .desktop: handOff(existing.id)
            case .chat: model.openChat(job: existing.id)
            case .paste: model.paste = PasteRequest(jobId: existing.id)
            case .automatic:
                model.show("\(existing.label) is already \(existing.state == .queued ? "queued" : "running").", link: ("View", .activity(jobId: existing.id)))
            }
            return
        }
        let route = route(for: task)
        let label = [task.activity, objectTitle(objectKind, objectId)].compactMap { $0 }.joined(separator: " ")
        do {
            switch route {
            case .engine(let ref):
                let id = try store.enqueueJob(task, args: args, objectKind: objectKind, objectId: objectId, label: label, mode: .automatic, engine: ref.string)
                model.refresh()
                let ahead = store.activeJobs().filter { $0.mode == .automatic && $0.id != id }.count
                model.show(ahead == 0 ? "\(task.label): started with \(ref.displayName)." : "\(task.label): queued behind \(ahead) job\(ahead == 1 ? "" : "s").",
                           link: ("View", .activity(jobId: id)))
                pump()
            case .chat(let ref):
                let id = try store.enqueueJob(task, args: args, objectKind: objectKind, objectId: objectId, label: label, mode: .chat, engine: ref.string)
                try store.setJobState(id, .waiting)
                model.refresh()
                model.openChat(job: id)
            case .handoff:
                let id = try store.enqueueJob(task, args: args, objectKind: objectKind, objectId: objectId, label: label, mode: .desktop,
                                              engine: ai.handoffApp.map { "app.\($0.id)" })
                model.refresh()
                handOff(id)
            case .paste:
                let id = try store.enqueueJob(task, args: args, objectKind: objectKind, objectId: objectId, label: label, mode: .paste, engine: "paste")
                try store.setJobState(id, .handedOff)
                model.refresh()
                model.paste = PasteRequest(jobId: id)
            }
        } catch { model.fail(error) }
    }

    /// Copies the prompt (with its job id) and opens the student's AI app.
    func handOff(_ id: Int) {
        guard let job = store.job(id) else { return }
        do {
            var args = job.args
            args["job_id"] = "\(id)"
            let text = try Prompts.render(job.task.prompt, args: args, store: store)
            ai.copy(text)
            if job.state == .queued { try store.setJobState(id, .handedOff) }
            let app = ai.handoffApp
            if let app { ai.open(app) }
            model.refresh()
            model.show("Prompt copied. Paste it into \(app?.name ?? "your AI app"); the job finishes when it saves its results.",
                       link: ("View", .activity(jobId: id)))
        } catch { model.fail(error) }
    }

    /// Hands a job to copy-and-paste instead (for apps that can't reach Study Tracker).
    func switchToPaste(_ id: Int) {
        guard let job = store.job(id), PastePrompts.supported.contains(job.task) else { return }
        try? store.setJobEngine(id, mode: .paste, engine: "paste")
        if job.state == .queued || job.state == .failed { try? store.setJobState(id, .handedOff) }
        model.refresh()
        model.paste = PasteRequest(jobId: id)
    }

    // MARK: Background queue

    /// Starts the next queued background job if none is running.
    func pump() {
        guard runningJobId == nil, let job = store.nextQueuedJob() else { return }
        guard let ref = EngineRef(string: job.engine) ?? ai.engine(for: job.task) else {
            try? store.setJobEngine(job.id, mode: .desktop, engine: nil)
            handOff(job.id)
            return pump()
        }
        runningJobId = job.id
        progressText = nil
        try? store.setJobState(job.id, .running)
        model.refresh()
        task = Task { [weak self] in
            guard let self else { return }
            let outcome: Result<String, Error>
            do { outcome = .success(try await self.execute(job, on: ref)) } catch { outcome = .failure(error) }
            self.finish(job.id, outcome)
        }
    }

    private func execute(_ job: ClaudeJob, on ref: EngineRef) async throws -> String {
        var args = job.args
        args["job_id"] = "\(job.id)"
        let pipeline = job.task == .process || job.task == .extractDeadlines
        if ref == .claudeCode && !pipeline {
            // Weekly plan and exam patterns explore with the tools: a capped Claude Code session.
            guard let cli = ai.claudeCLI(), let mcp = ai.mcpBinary else { throw AIError.unavailable("Claude Code or the Study Tracker server wasn't found.") }
            let prompt = try Prompts.render(job.task.prompt, args: args, store: store)
            let l = ai.launch
            let model = ai.claudeModel
            let r = try await CLIRunner.runClaude(cli: cli, prompt: prompt, mcpCommand: mcp.path, mcpEnvironment: l.env,
                                                  workingDirectory: ai.claudeWorkingDirectory, readableDirectory: store.paths.captures,
                                                  model: model) { [weak self] p in
                DispatchQueue.main.async { self?.process = p }
            }
            store.recordAIUsage(provider: ref.providerId, model: model, jobId: job.id, chatId: nil,
                                tokensIn: r.usage.inputTokens, tokensOut: r.usage.outputTokens, costUSD: nil)
            return r.text
        }
        let provider: LLMProvider
        let model: String
        if ref == .claudeCode {
            // Lectures and syllabi go through the same pipeline as every other engine: the app reads the material and
            // asks for JSON in a few one-shot requests, instead of a long tool-driving session on the student's plan.
            guard let cli = ai.claudeCLI() else { throw AIError.unavailable("Claude Code wasn't found.") }
            provider = ClaudeCodeProvider(cli: cli, workingDirectory: ai.claudeWorkingDirectory)
            model = ai.claudeModel
        } else {
            provider = try ai.provider(ref)
            model = ref.model ?? provider.descriptor.suggestedModel ?? "system"
        }
        let host = try MCPToolHost(paths: store.paths, allowed: job.task.toolNames, jobId: job.id)
        let meter = StoreUsageMeter(store: store, jobId: job.id)
        let progress: @Sendable (String) -> Void = { [weak self] text in Task { @MainActor in self?.progressText = text } }
        switch job.task {
        case .process:
            guard let mid = Int(job.args["material_id"] ?? "") else { throw AIError.badResponse("No material for this job.") }
            let r = try await Pipelines(provider: provider, model: model, host: host, store: store, meter: meter)
                .processLecture(materialId: mid, notesOnly: job.args["notes_only"] == "1", progress: progress)
            return ([r.summary] + r.warnings.prefix(2)).joined(separator: "\n")
        case .extractDeadlines:
            guard let mid = Int(job.args["material_id"] ?? "") else { throw AIError.badResponse("No material for this job.") }
            let r = try await Pipelines(provider: provider, model: model, host: host, store: store, meter: meter).extractDeadlines(materialId: mid, progress: progress)
            return ([r.summary] + r.warnings.prefix(2)).joined(separator: "\n")
        default:
            // Weekly plan, exam patterns: the model explores with the tools.
            progress("Working")
            var messages: [ChatMessage] = [.system(Prompts.studyRules), .user(try Prompts.render(job.task.prompt, args: args, store: store))]
            let (reply, _) = try await AgentLoop(provider: provider, model: model, host: host, meter: meter).run(&messages, stream: false)
            return reply.text
        }
    }

    private func finish(_ id: Int, _ outcome: Result<String, Error>) {
        process = nil
        task = nil
        runningJobId = nil
        progressText = nil
        let job = store.job(id)
        if job?.state == .canceled { model.refresh(); pump(); return }
        switch outcome {
        case .success(let reply):
            let summary = job.flatMap { store.job($0.id)?.resultSummary } ?? reply.split(separator: "\n").first.map { String($0.prefix(160)) }
            try? store.setJobState(id, .done, summary: summary)
            model.show("\(job?.task.label ?? "AI"): done. \(summary ?? "")", link: resultLink(id).map { ("Open", $0) })
        case .failure(let e):
            let message = (e as? LocalizedError)?.errorDescription ?? "\(e)"
            try? store.setJobState(id, .failed, error: message)
            var link: (String, StudyCore.Route) = ("View", .activity(jobId: id))
            if let ai = e as? AIError {
                switch ai {
                case .consentRequired, .auth, .modelGone, .budgetExceeded, .quotaExhausted, .unavailable: link = ("Settings", .connections(.ai))
                default: break
                }
            }
            model.show("Couldn't finish: \(message)", error: true, link: link)
        }
        model.refresh()
        pump()
    }

    // MARK: Job actions

    func cancel(_ id: Int) {
        try? store.setJobState(id, .canceled)
        if runningJobId == id { process?.terminate(); task?.cancel() }
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
    func resultLink(_ id: Int) -> StudyCore.Route? {
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

    /// Processes newly filed lectures in the background. Only the files just imported (`ids`), never the whole
    /// backlog, and never on a paid engine or the student's Claude plan unless they allowed it.
    func autoProcessReady(ids: Set<Int>) {
        guard !ids.isEmpty, case .engine(let ref) = route(for: .process) else { return }
        let free = ref.descriptor.map { $0.runsLocally || $0.isApple } ?? false
            || ref.model.flatMap { ai.settings.descriptor(ref.providerId)?.model($0)?.free } == true
        guard free || store.boolSetting("auto_process_paid") else { return }
        for m in store.unprocessedMaterials() where ids.contains(m.id) && m.role == .lecture && store.activeJob(.process, objectKind: "material", objectId: m.id) == nil {
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

/// A copy-and-paste job waiting for the student's chatbot answer.
struct PasteRequest: Identifiable { var jobId: Int; var id: Int { jobId } }
