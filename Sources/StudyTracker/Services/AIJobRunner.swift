import Foundation
import AppKit
import StudyCore
import StudyAI
import StudyMCPCore

/// Runs AI jobs so they just work.
/// - Two queues run side by side: everyday work (sorting and reading files with free AI) and course building, so a long
///   build never holds up a new file.
/// - When an engine fails, the job moves to the next one: a rate limit or a dropped connection waits and tries again;
///   anything else (a removed key, a used-up free tier, a model that went away) goes straight to the next engine. When
///   every engine has failed, a course-building job falls back to its basic version on free AI.
/// - Jobs survive a relaunch, and nothing is ever handed to the clipboard without the student asking.
/// - Work the app starts on its own (new files) is quiet: no toasts, and it pauses while the student is in a session.
@MainActor
@Observable
final class AIJobRunner {
    unowned let model: AppModel
    private var processes: [Int: Process] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    /// Queue lane → the job running in it.
    private(set) var running: [String: Int] = [:]
    private(set) var progress: [Int: String] = [:]
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        model.store.requeueInterruptedJobs()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
        // Wakes up for jobs that are backing off, and picks up what the last run left queued.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.pump()
        }
    }

    private var store: StudyStore { model.store }
    private var ai: AIService { model.ai }

    var runningJobId: Int? { running["builder"] ?? running["everyday"] }
    var isRunning: Bool { !running.isEmpty }
    var progressText: String? { runningJobId.flatMap { progress[$0] } }

    /// One quiet line for the window: what the AI is doing now.
    var statusLine: String? {
        if let id = running["builder"], let job = store.job(id) {
            if let p = store.builderProgress(id), job.task.engineLane == .builder {
                return "\(job.label) (\(p.done) of \(p.of) written)"
            }
            return progress[id] ?? job.label
        }
        guard let id = running["everyday"], let job = store.job(id) else { return nil }
        let waiting = store.queuedJobCount(lane: "everyday") - 1
        let now = progress[id] ?? job.label
        return waiting > 0 ? "\(now) · \(waiting) more waiting" : now
    }

    // MARK: Where a task runs

    enum Route: Equatable {
        case engine(EngineRef)
        case chat(EngineRef)
        case handoff
        case paste
        /// Nothing here can run it: the student needs to turn on an engine first.
        case unavailable
    }

    func route(for task: AITask) -> Route {
        guard !task.isRetired else { return .unavailable }
        let candidates = ai.candidates(for: task)
        if task.conversational {
            if let ref = candidates.first(where: { !$0.isCLI }) { return .chat(ref) }
            return ai.handoffApp != nil ? .handoff : .unavailable
        }
        if let ref = candidates.first { return .engine(ref) }
        return .unavailable
    }

    /// For buttons: the glyph that says where a task will run.
    func mode(for task: AITask) -> JobMode {
        switch route(for: task) {
        case .engine, .unavailable: return .automatic
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
        case .unavailable: return "Turn on Everyday AI in Settings first"
        }
    }

    // MARK: Starting jobs

    func run(_ task: AITask, material id: Int) { run(task, args: ["material_id": "\(id)"], objectKind: "material", objectId: id) }
    func run(_ task: AITask, assignment id: Int) { run(task, args: ["assignment_id": "\(id)"], objectKind: "assignment", objectId: id) }

    /// A job the student asked for: it reports where it runs and when it finishes.
    func run(_ task: AITask, args: [String: String] = [:], objectKind: String? = nil, objectId: Int? = nil) {
        if let existing = store.activeJob(task, objectKind: objectKind, objectId: objectId) {
            // A hand-off nobody finished within the hour is stale: start over rather than re-copying an old prompt.
            if existing.mode != .automatic && Date().timeIntervalSince(existing.createdAt) > 3600 {
                try? store.setJobState(existing.id, .canceled, error: "Started again.")
            } else {
                switch existing.mode {
                case .desktop: handOff(existing.id)
                case .chat: model.openChat(job: existing.id)
                case .paste: model.paste = PasteRequest(jobId: existing.id)
                case .automatic: model.show("\(task.label) is already \(existing.state == .queued ? "waiting its turn" : "running").")
                }
                return
            }
        }
        let label = [task.activity, objectTitle(objectKind, objectId)].compactMap { $0 }.joined(separator: " ")
        do {
            switch route(for: task) {
            case .engine(let ref):
                try store.enqueueJob(task, args: args, objectKind: objectKind, objectId: objectId, label: label, mode: .automatic, engine: ref.string)
                model.refresh()
                model.show("\(task.label): started with \(ref.displayName).")
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
            case .unavailable:
                model.show("\(task.label) needs AI. Turn on Everyday AI in Settings (Apple Intelligence or a free online model).",
                           error: true, link: ("Settings", .settings(.ai)))
            }
        } catch { model.fail(error) }
    }

    /// Work the app starts on its own (reading new files, building courses): no toasts, and only when an engine can run it.
    @discardableResult
    func enqueueQuiet(_ task: AITask, args: [String: String], objectKind: String?, objectId: Int?, courseId: Int?, priority: Int? = nil,
                      title: String? = nil) -> Int? {
        guard store.activeJob(task, objectKind: objectKind, objectId: objectId) == nil, !ai.candidates(for: task).isEmpty else { return nil }
        var args = args
        args["quiet"] = "1"
        let label = [task.activity, title ?? objectTitle(objectKind, objectId)].compactMap { $0 }.joined(separator: " ")
        let id = try? store.enqueueJob(task, args: args, objectKind: objectKind, objectId: objectId, label: label, mode: .automatic,
                                       priority: priority, courseId: courseId)
        pump()
        return id
    }

    /// Copies the prompt (with its job id) and opens the student's AI app. Only ever on the student's request.
    func handOff(_ id: Int) {
        guard let job = store.job(id) else { return }
        guard let prompt = job.task.prompt else { return model.show("\(job.task.label) runs inside Study Tracker, not in an AI app.") }
        do {
            var args = job.args
            args["job_id"] = "\(id)"
            args["quiet"] = nil
            let text = try Prompts.render(prompt, args: args, store: store)
            ai.copy(text)
            if job.state == .queued { try store.setJobState(id, .handedOff) }
            let app = ai.handoffApp
            if let app { ai.open(app) }
            model.refresh()
            model.show("Prompt copied. Paste it into \(app?.name ?? "your AI app"); the job finishes when it saves its results.")
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

    // MARK: Queues

    /// Starts the next job in each lane that's free. While the student is in a session, everyday work waits unless
    /// they're waiting for it.
    func pump() {
        for lane in ["everyday", "builder"] where running[lane] == nil {
            let urgentOnly = lane == "everyday" && model.studying
            guard let job = store.nextQueuedJob(lane: lane, maxPriority: urgentOnly ? 0 : .max) else { continue }
            start(job)
        }
    }

    private func start(_ job: ClaudeJob) {
        let candidates = ai.candidates(for: job.task).filter { !job.enginesTried.contains($0.string) }
        guard let ref = candidates.first else { return noEngineLeft(job) }
        running[job.task.queueLane] = job.id
        progress[job.id] = nil
        try? store.setJobEngine(job.id, mode: .automatic, engine: ref.string)
        try? store.setJobState(job.id, .running)
        model.refresh()
        tasks[job.id] = Task { [weak self] in
            guard let self else { return }
            let outcome: Result<String, Error>
            do { outcome = .success(try await self.execute(job, on: ref)) } catch { outcome = .failure(error) }
            self.finish(job.id, lane: job.task.queueLane, engine: ref, outcome)
        }
    }

    /// Every engine has failed (or none can run the task here): a strong-model task falls back to its basic version;
    /// anything else stops, and a quiet job stays quiet.
    private func noEngineLeft(_ job: ClaudeJob) {
        if let basic = job.task.degradesTo {
            if job.task.engineLane == .builder && !job.enginesTried.isEmpty {
                // The course builder failed everywhere (signed out, plan limit reached): free AI builds the basic
                // versions for a while instead of trying it again on every step.
                store.builderPausedUntil = Date().addingTimeInterval(6 * 3600)
                store.setSetting("ai_builder_paused_reason", job.error.map { String($0.prefix(200)) })
            }
            try? store.setJobTask(job.id, basic)
            model.refresh()
            return pump()
        }
        let reason = job.enginesTried.isEmpty
            ? "No AI engine here can do this yet. Turn on Everyday AI in Settings."
            : (job.error ?? "Every AI engine failed.")
        try? store.setJobState(job.id, .failed, error: reason)
        if !job.isQuiet { model.show("Couldn't finish \(job.task.label.lowercased()): \(reason)", error: true, link: ("Settings", .settings(.ai))) }
        model.refresh()
        pump()
    }

    private func execute(_ job: ClaudeJob, on ref: EngineRef) async throws -> String {
        var args = job.args
        args["job_id"] = "\(job.id)"
        args["quiet"] = nil
        if ref.isCLI {
            guard let prompt = job.task.prompt else { throw AIError.unavailable("\(job.task.label) doesn't run in Claude Code.") }
            guard let cli = ai.claudeCLI(), let mcp = ai.mcpBinary else { throw AIError.unavailable("Claude Code or the Study Tracker server wasn't found.") }
            let text = try Prompts.render(prompt, args: args, store: store)
            progress[job.id] = "\(job.label) with Claude Code"
            let l = ai.launch
            let id = job.id
            return try await CLIRunner.runClaude(cli: cli, prompt: text, mcpCommand: mcp.path, mcpEnvironment: l.env,
                                                 workingDirectory: store.paths.root, model: store.setting("ai_builder_cli_model")) { [weak self] p in
                DispatchQueue.main.async { self?.processes[id] = p }
            }
        }
        let provider = try ai.provider(ref)
        guard let modelId = ref.model ?? provider.descriptor.suggestedModel else {
            throw AIError.unavailable("Pick a model for \(provider.descriptor.name) in Settings › AI.")
        }
        let host = try MCPToolHost(paths: store.paths, allowed: job.task.toolNames, jobId: job.id)
        let builder = job.task.engineLane == .builder
        let meter = StoreUsageMeter(store: store, jobId: job.id, tokenCap: builder ? 1_500_000 : nil)
        let pipelines = Pipelines(provider: provider, model: modelId, host: host, store: store, meter: meter)
        let id = job.id
        let report: @Sendable (String) -> Void = { [weak self] text in Task { @MainActor in self?.progress[id] = text } }
        func material() throws -> Int {
            guard let mid = Int(job.args["material_id"] ?? "") else { throw AIError.badResponse("No file for this job.") }
            return mid
        }
        func course() throws -> Int {
            guard let cid = job.courseId ?? Int(job.args["course_id"] ?? "") else { throw AIError.badResponse("No course for this job.") }
            return cid
        }
        let r: PipelineReport
        switch job.task {
        case .sortFiles:
            let ids = (job.args["material_ids"] ?? "").split(separator: ",").compactMap { Int($0) }
            r = try await pipelines.sortFiles(materialIds: ids, progress: report)
        case .extractDeadlines:
            r = try await pipelines.extractDeadlines(materialId: try material(), progress: report)
        case .extractPractice, .extractExam:
            r = try await pipelines.labelPractice(materialId: try material(), progress: report)
        case .buildPathBasic:
            r = try await pipelines.buildPathBasic(courseId: try course(), progress: report)
        case .writeNotebookBasic:
            r = try await pipelines.writeNotebookBasic(courseId: try course(), topicIds: job.topicIds, progress: report)
        case .writeLessonsBasic:
            r = try await pipelines.writeLessonsBasic(courseId: try course(), topicIds: job.topicIds, progress: report)
        default:
            // The course builder on an API key, or a conversation task queued in the background (an AI app asked for
            // it): the model works with the tools.
            guard let prompt = job.task.prompt else { throw AIError.unavailable("\(job.task.label) doesn't run in the background.") }
            report("Working")
            var messages: [ChatMessage] = [.system(builder ? Prompts.builderRules : Prompts.studyRules), .user(try Prompts.render(prompt, args: args, store: store))]
            let limits = builder ? AgentLimits(maxIterations: 40, maxTotalTokens: 1_500_000) : AgentLimits()
            let (reply, _) = try await AgentLoop(provider: provider, model: modelId, host: host, limits: limits, meter: meter).run(&messages, stream: false)
            return reply.text
        }
        return ([r.summary] + r.warnings.prefix(2)).joined(separator: "\n")
    }

    private func finish(_ id: Int, lane: String, engine: EngineRef, _ outcome: Result<String, Error>) {
        processes[id] = nil
        tasks[id] = nil
        running[lane] = nil
        progress[id] = nil
        guard let job = store.job(id) else { return pump() }
        if job.state == .canceled { model.refresh(); return pump() }
        if job.state == .done {
            // Its own save finished it while the model was still wrapping up; whatever happened after doesn't matter.
            afterSuccess(job)
            model.refresh()
            return pump()
        }
        switch outcome {
        case .success where job.task.engineLane == .builder && !store.builderWorkDone(id):
            // The model stopped before writing everything. What it wrote is kept; the next run does the rest (on the
            // same engine once more, then the next one).
            let p = store.builderProgress(id)
            let message = p.map { "Stopped after writing \($0.done) of \($0.of)." } ?? "Stopped before saving the course path."
            try? store.requeueJob(id, failedEngine: job.attempts >= 1 ? engine.string : nil, error: message)
        case .success(let reply):
            let summary = store.job(id)?.resultSummary ?? reply.split(separator: "\n").first.map { String($0.prefix(160)) }
            try? store.setJobState(id, .done, summary: summary)
            afterSuccess(job)
            if !job.isQuiet { model.show("\(job.task.label): done. \(summary ?? "")") }
        case .failure(let e):
            let error = (e as? AIError) ?? (e is CancellationError ? .canceled : .badResponse((e as? LocalizedError)?.errorDescription ?? "\(e)"))
            let message = error.errorDescription ?? "\(error)"
            switch error {
            case .canceled:
                try? store.setJobState(id, .canceled)
            case .rateLimited(let wait) where job.attempts < 5:
                let delay = max(wait ?? 0, min(30 * pow(2, Double(job.attempts)), 1_800))
                try? store.requeueJob(id, notBefore: Date().addingTimeInterval(delay), error: message)
            case .network where job.attempts < 5:
                try? store.requeueJob(id, notBefore: Date().addingTimeInterval(min(30 * pow(2, Double(job.attempts)), 1_800)), error: message)
            case .quotaExhausted(_, let reset) where job.task.engineLane == .builder:
                // The student's Claude plan is used up for now: free AI builds the basic version meanwhile, and the
                // course builder picks up again once the limit lifts.
                store.builderPausedUntil = reset ?? Date().addingTimeInterval(6 * 3600)
                store.setSetting("ai_builder_paused_reason", "your Claude plan's usage limit was reached")
                try? store.requeueJob(id, failedEngine: engine.string, error: message)
            case .quotaExhausted(_, let reset):
                // Another engine may still have free requests; if not, this one is tried again when its allowance resets.
                let others = ai.candidates(for: job.task).filter { !job.enginesTried.contains($0.string) && $0 != engine }
                if others.isEmpty, let reset { try? store.requeueJob(id, notBefore: reset, error: message) }
                else { try? store.requeueJob(id, failedEngine: engine.string, error: message) }
            default:
                try? store.requeueJob(id, failedEngine: engine.string, error: message)
            }
        }
        model.refresh()
        pump()
    }

    /// What finishing one job sets off (here, or after the student pastes an answer back).
    func afterSuccess(_ job: ClaudeJob) {
        switch job.task {
        case .sortFiles:
            readNewFiles()
        case .extractDeadlines:
            if let mid = Int(job.args["material_id"] ?? "") { store.setReadState(mid, "done", engine: job.engine) }
            buildCourses()
        case .buildPath, .buildPathBasic:
            if let cid = job.courseId ?? Int(job.args["course_id"] ?? "") {
                // The new topics pick up the course's problems, cards and lectures, and keep the student's progress.
                for m in store.materials(courseId: cid) { store.linkCoverageByWords(materialId: m.id) }
                store.linkPracticeAndCards(courseId: cid)
                store.refreshMastery(courseId: cid)
            }
            buildCourses()
        case .writeNotebook, .writeNotebookBasic, .writeLessons, .writeLessonsBasic:
            buildCourses()
        default: break
        }
    }

    // MARK: Building courses

    /// Every course gets a path straight away, before any AI: one topic per lecture (a skeleton), with its problems and
    /// cards linked to the topics. Then the course builder (or free AI) takes over. Off the main thread.
    func prepareCourses() {
        let store = self.store
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for c in store.coursesToBuild() {
                _ = try? store.buildSkeletonPath(courseId: c.id)
                store.linkPracticeAndCards(courseId: c.id)
            }
            DispatchQueue.main.async {
                self?.model.refresh()
                self?.buildCourses()
            }
        }
    }

    /// Keeps every course's path, notebook guide and lessons coming, one step per course at a time in the builder
    /// queue: the full version when the student chose a course builder (or asked for this course), otherwise the basic
    /// version on free AI.
    func buildCourses() {
        let busy = Set(store.activeJobs().filter(\.task.isCourseBuilding).compactMap(\.courseId))
        for course in store.coursesToBuild() where !busy.contains(course.id) {
            guard let tier = builderTier(for: course.id), let step = store.nextBuilderStep(courseId: course.id, tier: tier),
                  !store.builderStepFailedRecently(step) else { continue }
            enqueueQuiet(step.task, args: step.args, objectKind: "course", objectId: course.id, courseId: course.id, title: step.title)
        }
    }

    /// `full` when the course builder can and should build this course (the student chose a course builder, or asked for
    /// this course), `basic` when only free AI can, nil with no AI. Never full on the student's Claude plan unasked.
    func builderTier(for courseId: Int) -> String? {
        let wanted = ai.settings.builderChosen || store.boolSetting("ai_builder_course.\(courseId)")
        if wanted && !store.builderPaused() && !ai.candidates(for: .buildPath).isEmpty { return "full" }
        return ai.candidates(for: .buildPathBasic).isEmpty ? nil : "basic"
    }

    /// The student opened a topic with no lesson yet: it's written now, ahead of everything else, on the best engine
    /// available (the warm-up and the notebook page buy it time).
    func requestLesson(topicId: Int) {
        guard let t = store.topic(topicId), let tier = builderTier(for: t.courseId) else { return }
        let task: AITask = tier == "full" ? .writeLessons : .writeLessonsBasic
        let step = BuilderStep(task: task, courseId: t.courseId, topicIds: [topicId], title: "\(store.course(t.courseId)?.displayName ?? "") · \(t.title)")
        if let queued = store.activeJobs().first(where: { $0.task.isCourseBuilding && $0.topicIds.contains(topicId) }) {
            try? store.db.execute("UPDATE claude_jobs SET priority = 0 WHERE id = ? AND state = 'queued'", [queued.id])
        } else {
            enqueueQuiet(task, args: step.args, objectKind: "topic", objectId: topicId, courseId: t.courseId, priority: 0, title: step.title)
        }
        pump()
    }

    /// Without Claude Code or a key: the student runs the next step of the full build in Claude Desktop (which saves
    /// through Study Tracker's tools) or pastes it into Claude.ai and pastes the answer back.
    func buildByHand(courseId: Int, inAIApp: Bool) {
        store.setBool("ai_builder_course.\(courseId)", true)
        guard let step = store.nextBuilderStep(courseId: courseId, tier: "full") else { return model.show("This course is already fully built.") }
        let label = [step.task.activity, step.title].joined(separator: " ")
        do {
            if inAIApp {
                let id = try store.enqueueJob(step.task, args: step.args, objectKind: "course", objectId: courseId, label: label, mode: .desktop,
                                              engine: ai.handoffApp.map { "app.\($0.id)" }, courseId: courseId)
                model.refresh()
                handOff(id)
            } else {
                let id = try store.enqueueJob(step.task, args: step.args, objectKind: "course", objectId: courseId, label: label, mode: .paste,
                                              engine: "paste", courseId: courseId)
                try store.setJobState(id, .handedOff)
                model.refresh()
                model.paste = PasteRequest(jobId: id)
            }
        } catch { model.fail(error) }
    }

    /// "Build with Claude" on one course: the course builder lays it out again and writes its notebook guide and
    /// lessons, replacing the basic versions.
    func buildWithBuilder(courseId: Int) {
        store.builderPausedUntil = nil
        store.setBool("ai_builder_course.\(courseId)", true)
        guard let ref = ai.candidates(for: .buildPath).first else {
            return model.show("No course builder is set up. Install Claude Code, or add an Anthropic API key in Settings › AI.", error: true,
                              link: ("Settings", .settings(.ai)))
        }
        for j in store.activeJobs() where j.courseId == courseId && j.task.isCourseBuilding && j.state == .queued {
            try? store.setJobState(j.id, .canceled, error: "Replaced by the course builder.")
        }
        guard let step = store.nextBuilderStep(courseId: courseId, tier: "full") else { return model.show("This course is already fully built.") }
        let label = [step.task.activity, step.title].joined(separator: " ")
        do {
            try store.enqueueJob(step.task, args: step.args, objectKind: "course", objectId: courseId, label: label, mode: .automatic,
                                 engine: ref.string, courseId: courseId)
            model.refresh()
            model.show("Building \(store.course(courseId)?.displayName ?? "the course") with \(ref.displayName). It takes a few minutes.")
            pump()
        } catch { model.fail(error) }
    }

    // MARK: Reading new files

    /// Sorts and reads new files with free AI, quietly, in the background: files the rules weren't sure about, the
    /// problems in practice files and past exams, and new syllabi. Called after imports, Moodle syncs and at launch.
    func readNewFiles() {
        // Problems are split out without AI as soon as a file is practice; this only catches files that weren't yet.
        for m in store.filesToSplit() { store.splitPractice(materialId: m.id) }
        let unsure = store.unsureFiles().filter {
            $0.roleSource != "ai" && $0.courseId != nil && !store.sortingInProgress($0.id) && !store.sortTried($0.id)
        }
        for (courseId, files) in Dictionary(grouping: unsure, by: { $0.courseId! }) {
            for start in stride(from: 0, to: files.count, by: 8) {
                let batch = files[start..<min(files.count, start + 8)]
                enqueueQuiet(.sortFiles, args: ["material_ids": batch.map { "\($0.id)" }.joined(separator: ",")],
                             objectKind: "materials", objectId: batch.first?.id, courseId: courseId)
            }
        }
        for m in store.filesWithUnlabelledPractice() {
            enqueueQuiet(m.role == .pastExam ? .extractExam : .extractPractice, args: ["material_id": "\(m.id)"],
                         objectKind: "material", objectId: m.id, courseId: m.courseId)
        }
        for m in store.syllabiToRead() {
            enqueueQuiet(.extractDeadlines, args: ["material_id": "\(m.id)"], objectKind: "material", objectId: m.id, courseId: m.courseId)
        }
        buildCourses()
    }

    // MARK: Job actions

    func cancel(_ id: Int) {
        try? store.setJobState(id, .canceled)
        processes[id]?.terminate()
        tasks[id]?.cancel()
        model.refresh()
    }

    func markDone(_ id: Int) {
        try? store.setJobState(id, .done)
        model.refresh()
    }

    func retry(_ id: Int) {
        guard let job = store.job(id) else { return }
        run(job.task, args: job.args.filter { $0.key != "quiet" }, objectKind: job.objectKind, objectId: job.objectId)
    }

    /// Stops any running Claude Code when the app quits, so nothing is left running behind it.
    func stopAll() {
        for p in processes.values { p.terminate() }
        for t in tasks.values { t.cancel() }
    }

    /// Where a job's results live.
    func resultLink(_ id: Int) -> StudyCore.Route? {
        guard let job = store.job(id) else { return nil }
        switch job.objectKind {
        case "course": return job.objectId.map { .course($0, .path) }
        case "material": return job.objectId.map { .material($0) }
        case "assignment": return job.objectId.map { .assignment($0) }
        default: return nil
        }
    }

    private func objectTitle(_ kind: String?, _ id: Int?) -> String? {
        guard let kind, let id else { return nil }
        switch kind {
        case "material": return store.material(id)?.title
        case "materials": return "new files"
        case "course": return store.course(id)?.displayName
        case "assignment": return store.assignment(id)?.title
        default: return nil
        }
    }
}

/// A copy-and-paste job waiting for the student's chatbot answer.
struct PasteRequest: Identifiable { var jobId: Int; var id: Int { jobId } }
