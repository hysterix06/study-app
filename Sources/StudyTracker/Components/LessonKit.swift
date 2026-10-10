import SwiftUI
import WebKit
import StudyCore

/// Lessons and notebook pages are drawn by LessonKit: a page with marked (Markdown) and KaTeX (maths) bundled in the app,
/// shown in a web view that can't reach the network. It loads only its own files, through the `lessonkit:` scheme, keeps
/// nothing between launches, and asks before opening a link in the browser. SwiftUI text can't show block Markdown,
/// maths or drawings; this can, in the theme's colours.
enum LessonKit {
    /// The bundled folder: in the app's Resources, or the repository's when run from `swift run` or the tests.
    static let directory: URL? = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("LessonKit"), FileManager.default.fileExists(atPath: r.appendingPathComponent("lesson.html").path) {
            return r
        }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Resources/LessonKit")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("lesson.html").path) { return candidate }
        }
        return nil
    }()

    static let pageURL = URL(string: "lessonkit://app/lesson.html")!

    /// The theme as CSS variables, so pages follow the app's look in light and dark.
    static func cssVariables(_ spec: ThemeSpec, dark: Bool) -> [String: String] {
        let t = spec.tokens(dark: dark)
        func css(_ token: ColorToken) -> String {
            let c = token.nominal(dark: dark)
            return String(format: "rgba(%d, %d, %d, %.3f)", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255), c.a)
        }
        let font: String
        var heading = "-apple-system, system-ui, sans-serif"
        switch spec.font {
        case .system: font = "-apple-system, system-ui, sans-serif"
        case .rounded: font = "ui-rounded, -apple-system, system-ui, sans-serif"; heading = font
        case .monospaced: font = "ui-monospace, SFMono-Regular, Menlo, monospace"; heading = font
        case .serifHeadings: font = "-apple-system, system-ui, sans-serif"; heading = "ui-serif, 'New York', Georgia, serif"
        }
        if spec.font == .system { heading = font }
        return ["text": css(t.textPrimary), "text2": css(t.textSecondary), "text3": css(t.textTertiary), "surface": css(t.surface),
                "canvas": css(t.canvas), "hairline": css(t.hairline), "fill": css(t.fillSubtle), "accent": css(t.attention),
                "words": css(t.textPrimary), "pictures": css(t.course(.ocean)), "dot": dark ? "rgba(255,255,255,.14)" : "rgba(0,0,0,.14)",
                "font": font, "heading-font": heading, "size": "\(Int(Theme.Size.s))px", "radius": "\(Int(spec.radiusCard))px"]
    }

    // MARK: Blocks

    /// One topic's notebook page guide.
    static func page(_ topic: PathTopic, number: String, guide: TopicNotebook?, showMark: Bool = true, markAction: Bool = false) -> [String: Any] {
        var b: [String: Any] = ["type": "page", "number": number, "title": topic.title]
        if showMark, topic.inNotebook { b["mark"] = "✓ Written" + (topic.notebookPage.map { " · p. \($0)" } ?? "") }
        if markAction { b["action"] = ["name": topic.inNotebook ? "unmark" : "mark", "id": topic.id, "label": topic.inNotebook ? "Change" : "Mark written"] }
        if let g = guide {
            b["terms"] = g.terms.map { t -> [String: Any] in
                var d: [String: Any] = ["term": t.term, "definition": t.definition]
                if let w = t.courseWording { d["wording"] = w; d["locator"] = t.locator ?? "" }
                return d
            }
            b["diagrams"] = g.diagrams.map { d -> [String: Any] in
                var x: [String: Any] = ["title": d.title, "draw": d.draw, "labels": d.labels]
                if let s = d.svg { x["svg"] = s }
                return x
            }
            b["formulas"] = g.formulas.map { ["latex": $0.latex, "meaning": $0.meaning] }
            b["links"] = g.links
        } else {
            b["pending"] = "This page's guide is still being written."
        }
        return b
    }

    /// A lesson: the question to think about, then its sections, each labelled by where it comes from.
    static func lesson(_ lesson: TopicLesson, store: StudyStore, sections kinds: Set<String>? = nil) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let q = lesson.preQuestion { out.append(["type": "question", "text": q]) }
        for s in lesson.sections where kinds?.contains(s.kind) ?? true {
            out.append(["type": "section", "kind": s.kind, "title": s.title, "md": s.bodyMd,
                        "sources": s.sourceChunkIds.isEmpty ? [] : store.chunks(ids: Array(s.sourceChunkIds.prefix(3))).map(\.locator)])
        }
        return out
    }

    static func payload(_ blocks: [[String: Any]], spec: ThemeSpec, dark: Bool) -> String {
        JSON.string(["theme": cssVariables(spec, dark: dark), "blocks": blocks])
    }
}

/// Shows LessonKit blocks. With `fitsContent`, the view is as tall as its content (for pages inside a SwiftUI scroll
/// view); otherwise it scrolls by itself.
struct LessonKitView: View {
    var blocks: [[String: Any]]
    var fitsContent = true
    /// A button on a page was pressed: its name and the id it carries.
    var onAction: ((String, Int) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themeSpec) private var spec
    @State private var height: CGFloat = 60

    var body: some View {
        let payload = LessonKit.payload(blocks, spec: spec, dark: scheme == .dark)
        if fitsContent {
            LessonWebView(payload: payload, height: $height, onAction: onAction).frame(height: height)
        } else {
            LessonWebView(payload: payload, height: $height, onAction: onAction)
        }
    }
}

/// Serves LessonKit's own files, and nothing outside its folder.
final class LessonKitSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let types = ["html": "text/html", "css": "text/css", "js": "text/javascript", "woff2": "font/woff2", "svg": "image/svg+xml", "png": "image/png"]
        let mime = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text") ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct LessonWebView: NSViewRepresentable {
    var payload: String
    @Binding var height: CGFloat
    var onAction: ((String, Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if let dir = LessonKit.directory { config.setURLSchemeHandler(LessonKitSchemeHandler(root: dir), forURLScheme: "lessonkit") }
        config.userContentController.add(context.coordinator, name: "size")
        config.userContentController.add(context.coordinator, name: "action")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        context.coordinator.pending = payload
        if LessonKit.directory != nil { web.load(URLRequest(url: LessonKit.pageURL)) }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.onAction = onAction
        context.coordinator.show(payload)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "size")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "action")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var onAction: ((String, Int) -> Void)?
        weak var web: WKWebView?
        var loaded = false
        var pending: String?
        var shown: String?

        init(height: Binding<CGFloat>) { self.height = height }

        func show(_ payload: String) {
            guard payload != shown else { return }
            guard loaded, let web else { pending = payload; return }
            shown = payload
            web.evaluateJavaScript("StudyKit.render(\(payload))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let p = pending { pending = nil; show(p) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "action" {
                guard let d = message.body as? [String: Any], let name = d["name"] as? String, let id = (d["id"] as? NSNumber)?.intValue else { return }
                DispatchQueue.main.async { self.onAction?(name, id) }
                return
            }
            guard let h = message.body as? NSNumber else { return }
            let value = CGFloat(truncating: h)
            if abs(height.wrappedValue - value) > 1 { DispatchQueue.main.async { self.height.wrappedValue = value } }
        }

        /// Only LessonKit's own page loads here; a link asks before it opens in the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == "lessonkit" && action.navigationType != .linkActivated { return decisionHandler(.allow) }
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

/// Prints LessonKit pages (or saves them as a PDF from the print panel), in the light theme with print styles.
@MainActor
final class LessonKitPrinter: NSObject, WKNavigationDelegate {
    static let shared = LessonKitPrinter()
    private var web: WKWebView?
    private var payload = ""
    private var title = ""

    func print(_ blocks: [[String: Any]], title: String) {
        guard let dir = LessonKit.directory else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(LessonKitSchemeHandler(root: dir), forURLScheme: "lessonkit")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 900), configuration: config)
        web.navigationDelegate = self
        self.web = web
        self.title = title
        payload = LessonKit.payload(blocks, spec: ThemeStore.shared.spec, dark: false)
        web.load(URLRequest(url: LessonKit.pageURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("StudyKit.render(\(payload))") { [weak self] _, _ in
            guard let self, let web = self.web else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.jobDisposition = .spool
            info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 40; info.rightMargin = 40
            info.isVerticallyCentered = false
            let op = web.printOperation(with: info)
            op.jobTitle = self.title
            op.view?.frame = web.bounds
            op.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}
