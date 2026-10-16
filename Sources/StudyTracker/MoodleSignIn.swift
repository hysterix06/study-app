import SwiftUI
import WebKit
import StudyCore

/// The one setup step Home shows until Moodle is connected: the school's address, then its own sign-in page.
struct ConnectMoodleCard: View {
    @Environment(AppModel.self) var model
    @State private var address = ""
    @State private var checking = false
    @State private var problem: String?
    @State private var launch: MoodleSSOLaunch?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.needsSignIn ? "Sign in to Moodle again" : "Connect your school's Moodle")
                .font(.serif(22, weight: .semibold))
            Text(model.needsSignIn
                 ? "Moodle ended the connection. Sign in once more and everything carries on."
                 : "Your courses, deadlines and course files come from Moodle. Nothing is ever changed there.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("elearning.yourschool.edu", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit(start)
                Button(model.needsSignIn ? "Sign in" : "Continue", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || MoodleClient.normalizeSite(address) == nil)
                if checking { ProgressView().controlSize(.small) }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        .onAppear { if address.isEmpty, let site = model.moodleSite { address = site.host ?? "" } }
        .sheet(item: $launch) { l in
            MoodleSSOSheet(launch: l) { token in Task { await model.connect(site: l.site, token: token) } }
        }
    }

    func start() {
        guard let typed = MoodleClient.normalizeSite(address) else { return }
        checking = true
        problem = nil
        Task {
            defer { checking = false }
            do {
                let profile = try await MoodleClient.siteProfile(site: typed)
                guard profile.appAccess else {
                    problem = "\(profile.name) doesn't let apps connect to Moodle. Ask your school to turn on the Moodle mobile app."
                    return
                }
                if !model.needsSignIn, let token = await model.existingToken(for: profile.site) {
                    await model.connect(site: profile.site, token: token)
                } else {
                    launch = MoodleSSOLaunch(site: profile.site, profile: profile)
                }
            } catch {
                problem = "No Moodle answered at that address. Check it against the one in your browser."
            }
        }
    }
}

struct MoodleSSOLaunch: Identifiable {
    let site: URL
    var profile: MoodleSiteProfile?
    let passport = UUID().uuidString
    var id: String { passport }
    var schoolName: String { profile?.name ?? site.host ?? "Moodle" }
}

/// The school's own sign-in page (Microsoft 365, Google, or Moodle's login) in a web view, which catches the token
/// reply the official Moodle app would receive. Cookies last only as long as the sheet.
struct MoodleSSOSheet: View {
    let launch: MoodleSSOLaunch
    let onToken: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var loading = true
    @State private var page: URL?
    @State private var problem: String?
    @State private var signedIn = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sign in to \(launch.schoolName)").font(.headline)
                    Text((page ?? launch.site).host ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading && !signedIn { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 10) }
            Divider()
            ZStack {
                MoodleLoginWebView(site: launch.site, passport: launch.passport, signInURL: launch.profile?.providerURL,
                                   loading: $loading, page: $page,
                                   onReply: { reply in
                                       do {
                                           let token = try MoodleClient.token(fromLaunchReply: reply)
                                           signedIn = true
                                           onToken(token)
                                           DispatchQueue.main.asyncAfter(deadline: .now() + 1) { dismiss() }
                                       } catch { problem = "\(error)" }
                                   },
                                   onFailure: { problem = $0 })
                if signedIn {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                        Text("Signed in").font(.title2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }
            }
            Divider()
            Text("Your password goes only to your school's sign-in page.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 560, height: 720)
    }
}

/// Sites set to "log in within the app" (common with Microsoft 365) refuse the launch page unless the session has only
/// just signed in. So a refusal sends the view to the school's sign-in, and once sign-in finishes, the redirect to the
/// dashboard is swapped for the launch page before anything else loads.
struct MoodleLoginWebView: NSViewRepresentable {
    let site: URL
    let passport: String
    var signInURL: URL?
    @Binding var loading: Bool
    @Binding var page: URL?
    let onReply: (URL) -> Void
    let onFailure: (String) -> Void

    var launchURL: URL { MoodleClient.launchURL(site: site, passport: passport) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: launchURL))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.parent = self }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        enum Phase { case launching, signingIn, fetchingKey }
        var parent: MoodleLoginWebView
        var phase = Phase.launching
        var leftLoginPage = false
        var replied = false
        init(_ parent: MoodleLoginWebView) { self.parent = parent }

        static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data"]

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.allow); return }
            guard Self.webSchemes.contains(url.scheme?.lowercased() ?? "") else {
                decisionHandler(.cancel)
                catchReply(url); return
            }
            if phase == .signingIn, action.targetFrame?.isMainFrame != false {
                let site = parent.site
                if url.host?.lowercased() != site.host?.lowercased() || action.navigationType == .formSubmitted || url.path.contains("/auth/") {
                    leftLoginPage = true
                }
                if leftLoginPage, !MoodleClient.isSignInPage(url, site: site) {
                    decisionHandler(.cancel)
                    phase = .fetchingKey
                    webView.load(URLRequest(url: parent.launchURL))
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            guard response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400,
                  http.url?.path.hasSuffix("/admin/tool/mobile/launch.php") == true else {
                decisionHandler(.allow); return
            }
            if phase == .launching {
                decisionHandler(.cancel)
                phase = .signingIn
                webView.load(URLRequest(url: parent.signInURL ?? parent.site.appendingPathComponent("login/index.php")))
            } else {
                decisionHandler(.allow)
                parent.onFailure("Moodle signed you in but wouldn't give Study Tracker its key. Its reason is below.")
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { parent.page = webView.url }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false; parent.page = webView.url }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            let ns = error as NSError
            // A redirect to the app scheme can surface as a failed load instead of a policy decision.
            if let failing = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String, let url = URL(string: failing),
               !Self.webSchemes.contains(url.scheme?.lowercased() ?? "") {
                catchReply(url); return
            }
            if (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return }
            parent.onFailure(ns.localizedDescription)
        }

        /// Sign-in buttons that open a new window load here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }

        func catchReply(_ url: URL) {
            guard !replied, url.absoluteString.contains("token=") else { return }
            replied = true
            parent.onReply(url)
        }
    }
}
