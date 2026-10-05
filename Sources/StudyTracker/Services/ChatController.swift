import Foundation
import StudyCore
import StudyAI
import StudyMCPCore

/// One conversation in the app's chat panel: recall, quiz, Feynman, draft check, practice, handwriting review, or a
/// free question. It runs the agent loop on the chosen engine with Study Tracker's tools, and keeps the transcript on
/// this Mac only.
@MainActor
@Observable
final class ChatController: Identifiable {
    struct Entry: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, event, error }
        let id = UUID()
        var role: Role
        var text: String
    }

    struct RatingRequest: Equatable {
        var cardId: Int
        var front: String
        var back: String
    }

    let id: Int
    unowned let model: AppModel
    private(set) var title: String
    private(set) var engine: EngineRef
    let task: AITask?
    let jobId: Int?
    private(set) var entries: [Entry] = []
    private(set) var streaming = ""
    private(set) var isRunning = false
    private(set) var pendingRating: RatingRequest?
    var attachments: [Data] = []
    private var conversation: [ChatMessage] = []
    private var runTask: Task<Void, Never>?
    private var ratingContinuation: CheckedContinuation<Rating?, Never>?

    static let chatNote = """
    You are chatting with the student inside the Study Tracker app. Keep replies short and conversational; use simple Markdown.
    To get the student's own flashcard rating, call ask_for_rating with the card id: the app shows them rating buttons and
    returns their choice. Never choose a rating yourself.
    """

    private init(id: Int, model: AppModel, chat: AIChat) {
        self.id = id
        self.model = model
        self.title = chat.title
        self.engine = EngineRef(string: chat.engine) ?? EngineRef(Catalog.appleOnDevice.id)
        self.task = chat.task
        self.jobId = chat.jobId
        let stored = model.store.chatMessages(id)
        var conv: [ChatMessage] = [.system(Prompts.studyRules + "\n\n" + Self.chatNote)]
        for m in stored {
            let hidden = m.dataJson?.contains("\"hidden\"") ?? false
            switch m.role {
            case "user":
                conv.append(.user(m.text))
                if !hidden { entries.append(Entry(role: .user, text: m.text)) }
            case "assistant":
                conv.append(.assistant(m.text))
                entries.append(Entry(role: .assistant, text: m.text))
            case "event": entries.append(Entry(role: .event, text: m.text))
            default: break
            }
        }
        conversation = conv
    }

    /// Opens the chat for a job, starting it if it's new.
    static func open(job jobId: Int, model: AppModel) throws -> ChatController {
        let store = model.store
        if let existing = store.chat(forJob: jobId) { return ChatController(id: existing.id, model: model, chat: existing) }
        guard let job = store.job(jobId) else { throw AIError.badResponse("That job no longer exists.") }
        var args = job.args
        args["job_id"] = "\(jobId)"
        let prompt = try Prompts.render(job.task.prompt, args: args, store: store)
        let engine = job.engine ?? model.ai.engine(for: job.task)?.string ?? Catalog.appleOnDevice.id
        let chatId = try store.createChat(task: job.task, args: job.args, objectKind: job.objectKind, objectId: job.objectId, jobId: jobId, title: job.label, engine: engine)
        try store.appendChatMessage(chatId, role: "user", text: prompt, dataJson: #"{"hidden":true}"#)
        let c = ChatController(id: chatId, model: model, chat: store.chat(chatId)!)
        c.start()
        return c
    }

    static func open(chat chatId: Int, model: AppModel) -> ChatController? {
        model.store.chat(chatId).map { ChatController(id: chatId, model: model, chat: $0) }
    }

    /// A free question with no task attached ("Ask about my courses").
    static func newChat(model: AppModel, engine: EngineRef) throws -> ChatController {
        let chatId = try model.store.createChat(task: nil, args: [:], objectKind: nil, objectId: nil, jobId: nil, title: "Chat", engine: engine.string)
        return ChatController(id: chatId, model: model, chat: model.store.chat(chatId)!)
    }

    var engineName: String { engine.displayName }
    var dataUse: String { engine.descriptor?.dataUse.label ?? "" }

    // MARK: Sending

    private func start() { run() }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !trimmed.isEmpty || !attachments.isEmpty else { return }
        var parts: [ContentPart] = [.text(trimmed.isEmpty ? "(photo)" : trimmed)]
        parts += attachments.map { .image($0, mimeType: "image/jpeg") }
        let display = trimmed + (attachments.isEmpty ? "" : "\n(\(attachments.count) photo\(attachments.count == 1 ? "" : "s") attached)")
        attachments = []
        conversation.append(ChatMessage(role: .user, parts: parts))
        entries.append(Entry(role: .user, text: display))
        _ = try? model.store.appendChatMessage(id, role: "user", text: display)
        if title == "Chat", entries.count == 1 {
            title = String(trimmed.prefix(60))
            _ = try? model.store.db.execute("UPDATE ai_chats SET title = ? WHERE id = ?", [title, id])
        }
        run()
    }

    private func run() {
        isRunning = true
        streaming = ""
        let engine = self.engine
        let jobId = self.jobId
        var conversation = self.conversation
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try model.ai.provider(engine)
                let base = try MCPToolHost(paths: model.store.paths, allowed: self.task?.toolNames ?? AITask.freeChatTools, blocked: ["log_review"], jobId: jobId)
                let host = ChatToolHost(base: base, chat: self)
                let meter = StoreUsageMeter(store: model.store, jobId: jobId, chatId: id)
                let modelId = engine.model ?? provider.descriptor.suggestedModel ?? "system"
                let loop = AgentLoop(provider: provider, model: modelId, host: host, meter: meter)
                let (reply, _) = try await loop.run(&conversation, stream: true) { [weak self] event in
                    Task { @MainActor in self?.handle(event) }
                }
                self.conversation = conversation
                self.finishTurn(reply.text)
            } catch {
                self.conversation = conversation
                self.fail(error)
            }
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .text(let t): streaming += t
        case .toolStarted(let name):
            if !streaming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(Entry(role: .assistant, text: streaming))
                streaming = ""
            }
            if let label = Self.toolLabel(name) { entries.append(Entry(role: .event, text: label)) }
        case .toolFinished(_, let isError):
            if isError, let last = entries.last, last.role == .event { entries[entries.count - 1].text = last.text + " (didn't work)" }
        case .usage: break
        }
    }

    private func finishTurn(_ text: String) {
        let final = streaming.isEmpty ? text : streaming
        streaming = ""
        if !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(Entry(role: .assistant, text: final))
            _ = try? model.store.appendChatMessage(id, role: "assistant", text: final)
        }
        isRunning = false
        model.refresh()
    }

    private func fail(_ error: Error) {
        streaming = ""
        isRunning = false
        pendingRating = nil
        if case AIError.canceled = error { return }
        if error is CancellationError { return }
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        entries.append(Entry(role: .error, text: message))
    }

    func stop() {
        runTask?.cancel()
        ratingContinuation?.resume(returning: nil)
        ratingContinuation = nil
        pendingRating = nil
    }

    func switchEngine(_ ref: EngineRef) {
        engine = ref
        model.store.setChatEngine(id, engine: ref.string)
        if let jobId { try? model.store.setJobEngine(jobId, mode: .chat, engine: ref.string) }
        entries.append(Entry(role: .event, text: "Switched to \(ref.displayName)"))
    }

    func delete() {
        stop()
        model.store.deleteChat(id)
        if let jobId, model.store.job(jobId)?.state.isActive == true { try? model.store.setJobState(jobId, .canceled) }
        model.refresh()
    }

    // MARK: Ratings

    /// Called by the tool host: shows the rating buttons and waits for the student's tap.
    func requestRating(cardId: Int) async -> Rating? {
        guard let card = model.store.card(cardId) else { return nil }
        if !streaming.isEmpty { entries.append(Entry(role: .assistant, text: streaming)); streaming = "" }
        pendingRating = RatingRequest(cardId: cardId, front: card.front, back: card.back)
        return await withCheckedContinuation { ratingContinuation = $0 }
    }

    func rate(_ rating: Rating) {
        guard pendingRating != nil else { return }
        pendingRating = nil
        entries.append(Entry(role: .event, text: "You rated it \(rating.label)"))
        ratingContinuation?.resume(returning: rating)
        ratingContinuation = nil
    }

    static func toolLabel(_ name: String) -> String? {
        switch name {
        case "get_overview": return "Looked at what's due"
        case "get_material", "get_chunks": return "Read the material"
        case "get_slide_images": return "Looked at the slides' pictures"
        case "get_concepts": return "Checked the concepts"
        case "get_questions", "get_review_queue": return "Picked questions"
        case "get_handwriting_captures": return "Read your handwritten notes"
        case "list_assignments", "get_grade_summary": return "Checked your assignments"
        case "list_materials": return "Looked through your materials"
        case "get_notes": return "Read your notes"
        case "save_note": return "Saved a note"
        case "save_questions": return "Saved practice questions"
        case "record_session": return "Recorded this session"
        case "propose_cards": return "Proposed flashcards for you to approve"
        case "ask_for_rating": return nil
        default: return nil
        }
    }
}

/// The Study Tracker tools plus one app-only tool: ask_for_rating, which shows the student rating buttons.
final class ChatToolHost: ToolHost, @unchecked Sendable {
    let base: MCPToolHost
    weak var chat: ChatController?

    init(base: MCPToolHost, chat: ChatController) { self.base = base; self.chat = chat }

    func specs() -> [ToolSpec] {
        base.specs() + [ToolSpec(name: "ask_for_rating",
                                 description: "Ask the student to rate their own recall of a flashcard (Again, Hard, Good, Easy). The app shows buttons and returns their rating.",
                                 parameters: ["type": "object", "properties": ["card_id": ["type": "integer", "description": "Card id"]], "required": ["card_id"]])]
    }

    func call(_ name: String, _ arguments: JSONValue) async -> ToolResult {
        guard name == "ask_for_rating" else { return await base.call(name, arguments) }
        guard let cardId = arguments["card_id"]?.int else { return ToolResult(text: "card_id is required.", isError: true) }
        guard let rating = await chat?.requestRating(cardId: cardId) else { return ToolResult(text: "The student didn't rate this card.", isError: true) }
        return await MainActor.run {
            guard let store = chat?.model.store else { return ToolResult(text: "The chat closed.", isError: true) }
            do {
                let r = try store.logReview(cardId: cardId, rating: rating)
                return ToolResult(text: "The student rated it \(rating.label). Next review \(FSRS.formatInterval(r.interval)).")
            } catch {
                return ToolResult(text: "Couldn't save the rating: \(error)", isError: true)
            }
        }
    }
}
