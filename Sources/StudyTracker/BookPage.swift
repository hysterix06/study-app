import SwiftUI
import WebKit
import StudyCore

/// A chapter on the book page (Resources/Book: marked and KaTeX, bundled), in a web view that can't reach the
/// network. It loads only its own files through the `bookkit:` scheme, keeps nothing between launches, and asks before
/// opening a link in the browser.
enum BookKit {
    /// The bundled folder: in the app's Resources, or the repository's when run from `swift run`.
    static let directory: URL? = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Book"), FileManager.default.fileExists(atPath: r.appendingPathComponent("book.html").path) {
            return r
        }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Resources/Book")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("book.html").path) { return candidate }
        }
        return nil
    }()

    static let pageURL = URL(string: "bookkit://app/book.html")!

    /// What the page draws for a chapter: parsed in Swift, figures already drawn or sanitised.
    static func payload(_ chapter: Chapter, course: Course?) -> [String: Any] {
        let doc = ChapterDoc.parse(chapter.markdown ?? "")
        var restore: (Int, Double)?
        if let pos = JSON.parse(chapter.readPos) as? [String: Any], let s = (pos["section"] as? NSNumber)?.intValue {
            restore = (s, (pos["fraction"] as? NSNumber)?.doubleValue ?? 0)
        }
        return doc.payload(kicker: course?.title, number: chapter.position, language: course?.bookLanguage ?? "en",
                           accent: CoursePalette.color(course?.color ?? 0), restore: restore.map { (section: $0.0, fraction: $0.1) })
    }
}

/// Serves the book page's own files, and nothing outside its folder.
final class BookKitSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let types = ["html": "text/html", "css": "text/css", "js": "text/javascript", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf"]
        let mime = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text") ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Present and read, driven from the toolbar.
@MainActor @Observable
final class BookPageControl {
    var presenting = false
    fileprivate weak var web: WKWebView?

    func set(presenting on: Bool) {
        guard on != presenting else { return }
        presenting = on
        web?.evaluateJavaScript(on ? "Book.present()" : "Book.read()")
        if on, let web { web.window?.makeFirstResponder(web) }
    }
}

struct BookPageView: NSViewRepresentable {
    let chapterId: Int
    let payload: [String: Any]
    let control: BookPageControl
    var onPosition: (Int, Double) -> Void
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if let dir = BookKit.directory { config.setURLSchemeHandler(BookKitSchemeHandler(root: dir), forURLScheme: "bookkit") }
        config.userContentController.add(context.coordinator, name: "book")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        control.web = web
        context.coordinator.web = web
        if BookKit.directory != nil { web.load(URLRequest(url: BookKit.pageURL)) }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        control.web = web
        context.coordinator.show()
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "book")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BookPageView
        weak var web: WKWebView?
        var loaded = false
        var shownChapter: Int?
        init(_ parent: BookPageView) { self.parent = parent }

        func show() {
            guard loaded, let web, shownChapter != parent.chapterId else { return }
            shownChapter = parent.chapterId
            parent.control.presenting = false
            web.callAsyncJavaScript("Book.render(payload)", arguments: ["payload": parent.payload], in: nil, in: .page) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            show()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "position":
                parent.onPosition((body["section"] as? NSNumber)?.intValue ?? 0, (body["fraction"] as? NSNumber)?.doubleValue ?? 0)
            case "reachedEnd":
                parent.onEnd()
            case "mode":
                parent.control.presenting = (body["mode"] as? String) == "present"
            default: break
            }
        }

        /// Only the book page loads here; a link asks before it opens in the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == "bookkit" && action.navigationType != .linkActivated { return decisionHandler(.allow) }
            decisionHandler(.cancel)
            guard ["http", "https"].contains(url.scheme ?? "") else { return }
            let alert = NSAlert()
            alert.messageText = "Open this link in your browser?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }
}

/// One chapter, read or presented, with the next and previous chapters a click away.
struct ChapterView: View {
    @Environment(AppModel.self) var model
    let courseId: Int
    @State var chapterId: Int
    @State private var control = BookPageControl()

    var body: some View {
        let _ = model.revision
        let course = model.course(courseId)
        let chapters = model.store.chapters(courseId: courseId)
        let index = chapters.firstIndex { $0.id == chapterId }
        Group {
            if let index, chapters[index].isReady {
                let ch = chapters[index]
                BookPageView(chapterId: ch.id, payload: BookKit.payload(ch, course: course), control: control,
                             onPosition: { model.store.saveReadPosition(ch.id, section: $0, fraction: $1) },
                             onEnd: { model.store.markRead(ch.id); model.reload() })
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Writing this chapter now. It takes a few minutes.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(index.map { "\($0 + 1). \(chapters[$0].title)" } ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button { move(-1, chapters, index) } label: { Image(systemName: "chevron.left") }
                    .help("Previous chapter").disabled((index ?? 0) == 0)
                Button { move(1, chapters, index) } label: { Image(systemName: "chevron.right") }
                    .help("Next chapter").disabled(index.map { $0 >= chapters.count - 1 } ?? true)
                Picker("View", selection: Binding(get: { control.presenting }, set: { control.set(presenting: $0) })) {
                    Text("Read").tag(false)
                    Text("Present").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Present shows the chapter as slides (P). Arrow keys move, Esc goes back.")
                .disabled(index.map { !chapters[$0].isReady } ?? true)
            }
        }
    }

    func move(_ step: Int, _ chapters: [Chapter], _ index: Int?) {
        guard let index, chapters.indices.contains(index + step) else { return }
        let next = chapters[index + step]
        chapterId = next.id
        model.open(next)
    }
}
