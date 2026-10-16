import Foundation

/// Writes the books in the background, one request at a time: each course's table of contents, then its chapters in
/// the order `BookStore.nextJob` gives. A plan or rate limit pauses it until the limit lifts (the pause is stored, so
/// it holds across relaunches); a network hiccup backs that one job off for a while; a chapter that fails twice stops
/// with its reason until the student asks for another try. Nothing runs until the student has chosen an engine.
public actor BookWriter {
    public struct Status: Equatable, Sendable {
        /// What's being written now ("Marketing · chapter 3").
        public var writing: String?
        public var pausedUntil: Date?
        public var pausedReason: String?
        public init(writing: String? = nil, pausedUntil: Date? = nil, pausedReason: String? = nil) {
            self.writing = writing; self.pausedUntil = pausedUntil; self.pausedReason = pausedReason
        }
    }

    /// The engine to write with and its model, or nil when the student hasn't chosen one.
    public typealias Engine = @Sendable () -> (provider: LLMProvider, model: String)?

    let store: BookStore
    let engine: Engine
    let clock: @Sendable () -> Date
    let onChange: @Sendable (Status) -> Void
    private var runner: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var focus: Int?
    private var backoff: [BookJob: (until: Date, tries: Int)] = [:]
    private var writing: String?

    public static let maxAttempts = 2

    public init(store: BookStore, engine: @escaping Engine, clock: @escaping @Sendable () -> Date = { Date() },
                onChange: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.store = store; self.engine = engine; self.clock = clock; self.onChange = onChange
    }

    /// At launch: anything cut off mid-write goes back in the queue, then work starts.
    public func start() {
        store.resetInterrupted()
        kick()
    }

    /// Something changed (files arrived, an engine was chosen): look for work.
    public func kick() {
        guard runner == nil else { return }
        runner = Task { await self.loop() }
    }

    /// The student opened this chapter: write it next.
    public func focus(on chapterId: Int?) {
        focus = chapterId
        kick()
    }

    public func retry(_ job: BookJob) {
        store.retry(job)
        backoff[job] = nil
        kick()
    }

    /// Lifts a pause early (the student signed in again, or changed engine).
    public func resume() {
        store.setSetting("ai_paused_until", nil)
        store.setSetting("ai_paused_reason", nil)
        report()
        kick()
    }

    /// Stops the request in flight (Claude Code is told to quit) and anything waiting.
    public func stop() async {
        runner?.cancel()
        wake?.cancel()
        _ = await runner?.value
    }

    public var status: Status {
        Status(writing: writing, pausedUntil: pausedUntil(), pausedReason: store.setting("ai_paused_reason"))
    }

    /// Waits for the current run of work to finish (tests).
    func idle() async { _ = await runner?.value }

    // MARK: The loop

    private func loop() async {
        defer { runner = nil; writing = nil; report() }
        while !Task.isCancelled {
            let now = clock()
            if let until = pausedUntil(), until > now { schedule(at: until); return }
            guard let (provider, model) = engine() else { return }
            let excluded = Set(backoff.filter { $0.value.until > now }.map(\.key))
            guard let job = store.nextJob(now: now, focus: focus, excluding: excluded) else {
                if let soonest = backoff.values.map(\.until).filter({ $0 > now }).min() { schedule(at: soonest) }
                return
            }
            await run(job, provider: provider, model: model)
        }
    }

    private func schedule(at date: Date) {
        wake?.cancel()
        let delay = max(1, date.timeIntervalSince(clock()))
        wake = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    private func pausedUntil() -> Date? { store.setting("ai_paused_until").flatMap { ISO.parse($0) } }

    private func report() { onChange(status) }

    private func run(_ job: BookJob, provider: LLMProvider, model: String) async {
        switch job {
        case .toc(let courseId): await writeContents(courseId, provider: provider, model: model)
        case .chapter(let id): await writeChapter(id, provider: provider, model: model)
        }
    }

    // MARK: Tables of contents

    private func writeContents(_ courseId: Int, provider: LLMProvider, model: String) async {
        let job = BookJob.toc(courseId: courseId)
        store.setTocState(courseId, "writing")
        writing = "Planning the book for \(store.course(courseId)?.name ?? "a course")"
        report()
        let (course, syllabus, files) = store.bookInputs(courseId: courseId)
        do {
            let request = ChatRequest(model: model, messages: [.system(BookPrompts.tocSystem), .user(BookPrompts.tocUser(course: course, syllabus: syllabus, files: files))],
                                      responseSchema: ResponseSchema(name: "book_plan", schema: JSONValue(any: BookPrompts.tocSchema)),
                                      maxOutputTokens: BookPrompts.tocMaxOutputTokens)
            let r = try await provider.send(request)
            let (plan, warnings) = BookPlan.parse(try SchemaPrompt.extractJSON(r.text).any, knownFiles: Set(files.map(\.id)))
            guard let plan else { throw BookError.unusable(warnings.last ?? "The table of contents couldn't be used.") }
            try store.saveBook(courseId: courseId, plan: plan, model: model, usage: (r.usage.inputTokens, r.usage.outputTokens), now: clock())
            backoff[job] = nil
        } catch {
            handle(error, job: job)
        }
    }

    // MARK: Chapters

    private func writeChapter(_ id: Int, provider: LLMProvider, model: String) async {
        let job = BookJob.chapter(id: id)
        guard let ch = store.chapter(id), let plan = store.bookPlan(courseId: ch.courseId), plan.chapters.indices.contains(ch.position - 1) else {
            store.setChapterState(id, "failed", error: "This chapter's book is missing.")
            return
        }
        store.setChapterState(id, "writing")
        writing = "\(plan.title) · chapter \(ch.position)"
        report()
        let (course, syllabus, files) = store.bookInputs(courseId: ch.courseId)
        let mine = files.filter { ch.fileIds.contains($0.id) }
        let prompt = BookPrompts.chapterCourseBlock(course: course, plan: plan, syllabus: syllabus) + "\n\n"
            + BookPrompts.chapterBlock(number: ch.position, chapter: plan.chapters[ch.position - 1], files: mine)
        let started = clock()
        do {
            let r = try await provider.stream(ChatRequest(model: model, messages: [.system(BookPrompts.chapterSystem), .user(prompt)],
                                                          maxOutputTokens: BookPrompts.chapterMaxOutputTokens)) { _ in }
            let doc = ChapterDoc.parse(r.text)
            if let problem = doc.problems.first { throw BookError.unusable("The chapter came back too thin: \(problem).") }
            try store.saveChapter(id, markdown: r.text, doc: doc, engine: provider.name, model: model, usage: (r.usage.inputTokens, r.usage.outputTokens),
                                  milliseconds: Int(clock().timeIntervalSince(started) * 1000), now: clock())
            backoff[job] = nil
        } catch {
            handle(error, job: job)
        }
    }

    // MARK: When something goes wrong

    enum BookError: Error, CustomStringConvertible {
        case unusable(String)
        var description: String { if case .unusable(let m) = self { return m }; return "" }
    }

    private func handle(_ error: Error, job: BookJob) {
        let now = clock()
        func requeue() {
            switch job {
            case .toc(let c): store.setTocState(c, "queued")
            case .chapter(let id): store.setChapterState(id, "queued")
            }
        }
        if error is CancellationError { requeue(); return }
        switch error as? AIError {
        case .canceled?:
            requeue()
        case .quotaExhausted(let message, let reset)?:
            requeue()
            pause(until: reset ?? now.addingTimeInterval(3600), reason: message)
        case .auth(let message)?:
            requeue()
            pause(until: now.addingTimeInterval(30 * 60), reason: message)
        case .rateLimited?, .network?:
            requeue()
            let tries = (backoff[job]?.tries ?? 0) + 1
            backoff[job] = (now.addingTimeInterval([60, 300, 900][min(tries, 3) - 1]), tries)
        default:
            let message = (error as? AIError)?.errorDescription ?? "\(error)"
            switch job {
            case .toc(let c):
                let attempts = ((try? store.db.scalarInt("SELECT toc_attempts FROM courses WHERE id = ?", [c])) ?? 0) + 1
                store.setTocState(c, attempts >= Self.maxAttempts ? "failed" : "queued", error: message, countAttempt: true)
            case .chapter(let id):
                let attempts = (store.chapter(id)?.attempts ?? 0) + 1
                store.setChapterState(id, attempts >= Self.maxAttempts ? "failed" : "queued", error: message, countAttempt: true)
            }
        }
    }

    private func pause(until: Date, reason: String) {
        store.setSetting("ai_paused_until", ISO.instant(until))
        store.setSetting("ai_paused_reason", reason)
        report()
    }
}
