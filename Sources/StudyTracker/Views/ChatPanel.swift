import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StudyCore
import StudyAI

/// The app's chat: conversations about the student's own material, on whichever engine they chose.
struct ChatPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @Bindable var chat: ChatController
    @State private var draft = ""
    @State private var confirmDelete = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let r = chat.pendingRating { ratingBar(r) }
            Divider()
            input
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 680)
        .onAppear { inputFocused = true }
        .confirmationDialog("Delete this chat?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { chat.delete(); dismiss() }
        } message: { Text("The conversation is removed from this Mac. Anything already saved (notes, sessions) stays.") }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.stBodyStrong).lineLimit(1)
                Text(chat.dataUse).font(.stSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            Menu {
                ForEach(model.ai.engineOptions().filter { !$0.ref.isCLI }) { o in
                    let fit = chat.task.map { model.ai.fit($0, o.ref) } ?? .good
                    Button { chat.switchEngine(o.ref) } label: {
                        Text(o.title + (o.free ? " · free" : "") + (fit.note != nil ? " · basic" : ""))
                    }.disabled(!fit.isUsable)
                }
                Divider()
                Button("AI settings…") { dismiss(); model.go(.connections(.ai)) }
            } label: { Text(chat.engineName).font(.stSmall) }
                .menuStyle(.borderlessButton).fixedSize().disabled(chat.isRunning)
            Button { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete chat")
            Button("Done") { chat.stop(); dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.entries.isEmpty && !chat.isRunning {
                        Text(chat.task == nil ? "Ask anything about your courses, deadlines or lectures." : "Starting…")
                            .font(.stBody).foregroundStyle(Theme.textSecondary).padding(.top, 20)
                    }
                    ForEach(chat.entries) { e in bubble(e) }
                    if !chat.streaming.isEmpty { bubble(.init(role: .assistant, text: chat.streaming)) }
                    if chat.isRunning && chat.streaming.isEmpty && chat.pendingRating == nil {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").font(.stSmall).foregroundStyle(Theme.textTertiary) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .onChange(of: chat.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.streaming) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    @ViewBuilder func bubble(_ e: ChatController.Entry) -> some View {
        switch e.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(e.text).font(.stBody).textSelection(.enabled)
                    .padding(10).background(RoundedRectangle(cornerRadius: Theme.corner(10)).fill(Theme.fillSubtle))
            }
        case .assistant:
            ReplyView(text: e.text)
        case .event:
            Label(e.text, systemImage: "checkmark.circle").font(.stSmall).foregroundStyle(Theme.textTertiary)
        case .error:
            VStack(alignment: .leading, spacing: 6) {
                Label(e.text, systemImage: "exclamationmark.triangle.fill").font(.stSmall).foregroundStyle(Theme.attention)
                Button("AI settings") { model.go(.connections(.ai)) }.buttonStyle(.borderless).font(.stSmall)
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    func ratingBar(_ r: ChatController.RatingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How well did you remember it? Your rating schedules the next review.").font(.stSmall).foregroundStyle(Theme.textSecondary)
            Text(r.front).font(.stBodyStrong).lineLimit(2)
            HStack(spacing: 8) {
                ForEach(Rating.allCases, id: \.self) { rating in
                    Button("\(rating.rawValue)  \(rating.label)") { chat.rate(rating) }
                        .keyboardShortcut(KeyEquivalent(Character("\(rating.rawValue)")), modifiers: [])
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface)
    }

    var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.attachments.isEmpty {
                HStack {
                    Label("\(chat.attachments.count) photo\(chat.attachments.count == 1 ? "" : "s")", systemImage: "photo").font(.stSmall)
                    Button("Remove") { chat.attachments = [] }.buttonStyle(.borderless).font(.stSmall)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { attachPhoto() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless).help("Attach a photo (e.g. your handwritten sheet)")
                TextField("Reply…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.stBody).lineLimit(1...6).focused($inputFocused)
                    .onSubmit { sendDraft() }
                    .disabled(chat.pendingRating != nil)
                if chat.isRunning {
                    Button("Stop") { chat.stop() }.buttonStyle(QuietButtonStyle())
                } else {
                    Button("Send") { sendDraft() }.buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.attachments.isEmpty)
                }
            }
        }
        .padding(12)
    }

    func sendDraft() {
        guard !chat.isRunning else { return }
        chat.send(draft)
        draft = ""
    }

    func attachPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.directoryURL = model.store.paths.captures
        guard panel.runModal() == .OK else { return }
        chat.attachments += panel.urls.compactMap { Imaging.loadImage($0, maxPixel: 1600).flatMap { Imaging.jpegData($0) } }
    }
}

/// "Copy for any chatbot": prompts to paste into ChatGPT, Gemini, Brave Leo or anything else, and a box for the answer.
struct PasteSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let request: PasteRequest
    @State private var answer = ""
    @State private var parts: [String] = []
    @State private var copied: Set<Int> = []
    @State private var importing = false
    @State private var report: PipelineReport?
    @State private var error: String?

    var body: some View {
        let job = model.store.job(request.jobId)
        VStack(alignment: .leading, spacing: 14) {
            Text(job?.label ?? "Copy for any chatbot").font(.stHeading)
            Text("No AI is set up to do this here, so use any chatbot: free ChatGPT, Gemini, Claude, Brave Leo or another. Your material goes to whichever one you paste it into.")
                .font(.stSmall).foregroundStyle(Theme.textSecondary)
            Panel {
                SectionHeader(title: "1. Copy the prompt\(parts.count > 1 ? " (\(parts.count) parts; paste each one)" : "")")
                HStack {
                    ForEach(parts.indices, id: \.self) { i in
                        Button(copied.contains(i) ? "Copied part \(i + 1)" : parts.count > 1 ? "Copy part \(i + 1)" : "Copy prompt") {
                            model.ai.copy(parts[i]); copied.insert(i)
                        }.buttonStyle(i == 0 && copied.isEmpty ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(QuietButtonStyle()))
                    }
                }
                HStack(spacing: 12) {
                    ForEach([("ChatGPT", "https://chatgpt.com"), ("Gemini", "https://gemini.google.com"), ("Claude", "https://claude.ai/new"), ("Duck.ai", "https://duck.ai")], id: \.0) { name, url in
                        Link(name, destination: URL(string: url)!).font(.stSmall)
                    }
                }
            }
            Panel {
                SectionHeader(title: "2. Paste the chatbot's answer\(parts.count > 1 ? "s" : "") here")
                TextEditor(text: $answer).font(.system(size: 12, design: .monospaced)).frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                Text("Study Tracker checks everything first: items that don't point at this material are skipped, and unclear dates are left out.")
                    .font(.stSmall).foregroundStyle(Theme.textTertiary)
            }
            if let report {
                Label(report.summary, systemImage: "checkmark.circle.fill").font(.stSmall).foregroundStyle(Theme.success)
                ForEach(report.warnings.prefix(4), id: \.self) { Text($0).font(.stSmall).foregroundStyle(Theme.textSecondary) }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.stSmall).foregroundStyle(Theme.attention) }
            HStack {
                Button("Cancel job") { model.jobs.cancel(request.jobId); dismiss() }.buttonStyle(.borderless)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if report == nil {
                    Button(importing ? "Importing…" : "Import") { importAnswer(job) }.buttonStyle(PrimaryButtonStyle())
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importing)
                }
            }
        }
        .padding(22).frame(width: 600)
        .onAppear {
            guard let job, let mid = Int(job.args["material_id"] ?? "") else { error = "This job has nothing to copy."; return }
            do { parts = try PastePrompts(store: model.store).prompts(job.task, materialId: mid) } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    func importAnswer(_ job: ClaudeJob?) {
        guard let job, let mid = Int(job.args["material_id"] ?? "") else { return }
        importing = true
        error = nil
        let store = model.store
        let text = answer
        Task {
            do {
                let host = try MCPToolHost(paths: store.paths, jobId: job.id)
                let r = try await PastePrompts(store: store).importAnswer(job.task, materialId: mid, text: text, host: host)
                report = r
                try? store.setJobState(job.id, .done, summary: r.summary)
                model.refresh()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            importing = false
        }
    }
}
