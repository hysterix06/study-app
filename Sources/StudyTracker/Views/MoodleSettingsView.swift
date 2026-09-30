import SwiftUI
import AppKit
import WebKit
import StudyCore

// MARK: - Moodle settings

/// Two states. Before: one card with one action. After: the live connection, what it has brought in, the courses it
/// covers, and how the account is kept safe.
struct MoodleSettings: View {
    @Environment(AppModel.self) var model
    @State private var launch: MoodleSSOLaunch?
    /// Set when a connection completes on this screen, for the first-import progress and the welcome.
    @State private var justConnected = false

    var body: some View {
        let _ = model.revision
        let connected = model.moodle.isConnected
        Group {
            if connected {
                MoodleConnectedView(justConnected: $justConnected, signIn: { launch = $0 })
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                MoodleConnectView(signIn: { launch = $0 }, connected: startFirstImport)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: connected)
        // Held here rather than in the connect card, so the sheet can finish its "Signed in" moment while the card
        // underneath turns into the connected view.
        .sheet(item: $launch) { l in
            MoodleSSOSheet(launch: l) { token in
                if let p = l.profile { model.moodle.remember(p) }
                model.moodle.useToken(site: l.site.absoluteString, token: token, method: "sso")
                startFirstImport()
            }
        }
    }

    func startFirstImport() {
        justConnected = true
        Task { await model.moodle.sync(silent: true) }
    }
}

enum MoodleSignInMethod: Hashable { case password, key }

struct MoodleSSOLaunch: Identifiable {
    let site: URL
    var profile: MoodleSiteProfile?
    let passport = UUID().uuidString
    var id: String { passport }
    var schoolName: String { profile?.name ?? site.host ?? "Moodle" }
}

// MARK: Not connected

struct MoodleConnectView: View {
    @Environment(AppModel.self) var model
    let signIn: (MoodleSSOLaunch) -> Void
    let connected: () -> Void

    enum Lookup: Equatable { case idle, checking, found(MoodleSiteProfile), notFound }
    @State private var site = ""
    @State private var lookup = Lookup.idle
    @State private var otherWays = false
    @State private var method = MoodleSignInMethod.password
    @State private var username = ""
    @State private var password = ""
    @State private var key = ""
    @State private var working = false

    var profile: MoodleSiteProfile? { if case .found(let p) = lookup { return p } else { return nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            card
            MoodleFeatureTiles()
            otherWaysSection
        }
        .onAppear {
            if site.isEmpty, let saved = model.store.setting("moodle_url") { site = saved.replacingOccurrences(of: "https://", with: "") }
        }
        .task(id: site) { await lookUp() }
    }

    var card: some View {
        VStack(spacing: 22) {
            MoodleLinkGraphic(state: .idle, logoURL: profile?.logoURL)
            VStack(spacing: 6) {
                Text("Connect your Moodle").font(.stHeading)
                Text("Deadlines, grades and new course files come in on their own and stay up to date.")
                    .font(.stBody).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Your school's Moodle address").font(.stSmallStrong).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(Theme.tertiaryText)
                    TextField("", text: $site, prompt: Text("moodle.yourschool.edu"))
                        .textFieldStyle(.plain).font(.stBody)
                        .onSubmit { if canSignIn { startSignIn() } }
                    lookupIcon
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14)))
                lookupCaption.font(.stSmall).frame(minHeight: 16, alignment: .top)
            }
            VStack(spacing: 12) {
                Button(action: startSignIn) {
                    Label(profile?.providerName.map { "Connect with \($0)" } ?? "Connect Moodle", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSignIn)
                Label("You'll sign in on your school's own page. Study Tracker never reads or stores your password.", systemImage: "lock.shield")
                    .font(.stSmall).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
    }

    @ViewBuilder var lookupIcon: some View {
        switch lookup {
        case .checking: ProgressView().controlSize(.small)
        case .found(let p) where p.appAccess: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .found: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
        case .notFound: Image(systemName: "questionmark.circle").foregroundStyle(Theme.tertiaryText)
        case .idle: EmptyView()
        }
    }

    @ViewBuilder var lookupCaption: some View {
        switch lookup {
        case .found(let p) where p.appAccess:
            if let provider = p.providerName {
                Text("Found \(Text(p.name).fontWeight(.semibold)) · signs in with \(provider)").foregroundStyle(Theme.secondaryText)
            } else {
                Text("Found \(Text(p.name).fontWeight(.semibold))").foregroundStyle(Theme.secondaryText)
            }
        case .found(let p):
            Text("\(p.name) has turned off app access, so Moodle can't connect. You can still get deadlines by adding its calendar link in Connections › Calendars.")
                .foregroundStyle(Theme.accent)
        case .notFound:
            Text("No Moodle found here yet. Copy the address from your browser while you're on Moodle.").foregroundStyle(Theme.secondaryText)
        case .idle, .checking:
            Text(" ")
        }
    }

    var canSignIn: Bool {
        switch lookup {
        case .found(let p): return p.appAccess
        // Some sites hide their public details; the sign-in page will still say what's wrong.
        case .notFound: return MoodleClient.normalizeSite(site) != nil
        case .idle, .checking: return false
        }
    }

    func startSignIn() {
        if let p = profile { signIn(MoodleSSOLaunch(site: p.site, profile: p)) }
        else if let url = MoodleClient.normalizeSite(site) { signIn(MoodleSSOLaunch(site: url)) }
    }

    func lookUp() async {
        guard let url = MoodleClient.normalizeSite(site), url.host?.contains(".") == true else { lookup = .idle; return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        lookup = .checking
        let found = try? await MoodleClient.siteProfile(site: url)
        guard !Task.isCancelled else { return }
        lookup = found.map { .found($0) } ?? .notFound
    }

    var otherWaysSection: some View {
        DisclosureGroup(isExpanded: $otherWays) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $method) {
                    Text("Username and password").tag(MoodleSignInMethod.password)
                    Text("Security key").tag(MoodleSignInMethod.key)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if method == .password {
                    TextField("Moodle username", text: $username).textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    Text("For schools without single sign-on. The password is used once to get a key, then discarded.")
                        .font(.stSmall).foregroundStyle(Theme.secondaryText)
                } else {
                    SecureField("Moodle mobile web service key", text: $key).textFieldStyle(.roundedBorder)
                    Text("In Moodle: your profile → Preferences → Security keys → copy the \"Moodle mobile web service\" key.")
                        .font(.stSmall).foregroundStyle(Theme.secondaryText)
                }
                Button(working ? "Connecting…" : "Connect") { connectOther() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(working || MoodleClient.normalizeSite(site) == nil || (method == .password ? username.isEmpty || password.isEmpty : key.isEmpty))
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.top, 10)
        } label: {
            Text("Other ways to connect").font(.stBody).foregroundStyle(Theme.secondaryText)
        }
    }

    func connectOther() {
        let address = profile?.site.absoluteString ?? site
        working = true
        Task {
            do {
                if method == .key { model.moodle.useToken(site: address, token: key, method: "key") }
                else { try await model.moodle.signIn(site: address, username: username, password: password) }
                if let p = profile { model.moodle.remember(p) }
                password = ""; key = ""
                connected()
            } catch { model.fail(error) }
            working = false
        }
    }
}

/// What a connection brings in, so the one action has a clear payoff.
struct MoodleFeatureTiles: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What comes in")
            HStack(alignment: .top, spacing: 12) {
                tile("calendar.badge.clock", "Deadlines", "Assignments and quizzes, with their due dates")
                tile("checkmark.seal", "Grades", "Scores as soon as teachers release them")
                tile("doc.richtext", "Course files", "New slides and PDFs, filed under the right course")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    func tile(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(height: 22)
            Text(title).font(.system(size: Theme.Size.s, weight: .semibold))
            Text(detail).font(.stSmall).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.hairline))
    }
}

// MARK: Connected

struct MoodleConnectedView: View {
    @Environment(AppModel.self) var model
    @Binding var justConnected: Bool
    let signIn: (MoodleSSOLaunch) -> Void
    @State private var confirmDisconnect = false
    @State private var reconnecting = false

    var schoolName: String { model.store.setting("moodle_site_name") ?? model.moodle.site?.host ?? "Moodle" }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            statusCard
            coursesSection
            syncSection
            securitySection
        }
        .task {
            // Connections made before the school's details were kept get its name, logo and sign-in button here.
            guard model.store.setting("moodle_logo_url") == nil, let site = model.moodle.site,
                  let profile = try? await MoodleClient.siteProfile(site: site) else { return }
            model.moodle.remember(profile)
            model.refresh()
        }
        .confirmationDialog("Disconnect Moodle?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { justConnected = false; model.moodle.signOut() }
        } message: {
            Text("Study Tracker deletes its Moodle key from your Keychain. Deadlines, grades and files already imported stay.")
        }
    }

    // MARK: Status

    var statusCard: some View {
        let store = model.store
        let svc: MoodleService = model.moodle
        let needsSignIn = store.boolSetting("moodle_needs_signin")
        let importing = justConnected && svc.syncing
        let site = svc.site
        let user = store.setting("moodle_user_name")
        let graphic: MoodleLinkGraphic.LinkState = needsSignIn ? .broken : importing ? .connecting : .connected
        return VStack(spacing: 20) {
            MoodleLinkGraphic(state: graphic, logoURL: store.setting("moodle_logo_url").flatMap(URL.init(string:)), animateIn: justConnected)
            VStack(spacing: 8) {
                if needsSignIn {
                    StatusPill(text: "Sign-in expired", systemImage: "exclamationmark.triangle.fill", color: Theme.accent)
                } else if importing {
                    StatusPill(text: "Importing from Moodle", systemImage: "arrow.down.circle.fill", color: Theme.success)
                } else {
                    StatusPill(text: "Connected securely", systemImage: "lock.fill", color: Theme.success)
                }
                Text(schoolName).font(.stHeading).multilineTextAlignment(.center)
                Text([site?.host, user.map { "Signed in as \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.stSmall).foregroundStyle(Theme.secondaryText)
            }
            if importing {
                firstImportSteps
            } else {
                if justConnected, !needsSignIn { welcome }
                statsRow
            }
            if !importing {
                Divider()
                if needsSignIn { expiredFooter } else { syncFooter }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(needsSignIn ? Theme.accent.opacity(0.35) : Theme.success.opacity(0.35)))
    }

    var firstImportSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(.done, "Signed in securely")
            step(.active, "Importing courses, deadlines, grades and files")
            step(.waiting, "Ready")
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(.vertical, 4)
    }

    enum StepState { case done, active, waiting }

    func step(_ state: StepState, _ text: String) -> some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .active: ProgressView().controlSize(.small)
                case .waiting: Image(systemName: "circle").foregroundStyle(Theme.tertiaryText)
                }
            }
            .frame(width: 18)
            Text(text).font(.stBody).foregroundStyle(state == .waiting ? Theme.tertiaryText : Color.primary)
        }
    }

    /// The result of the first import, shown once, right after connecting.
    @ViewBuilder var welcome: some View {
        let report = model.moodle.lastReport
        let linkedNone = MoodleSync.stats(store: model.store).courses == 0
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report?.errors.isEmpty == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(report?.errors.isEmpty == false ? Theme.accent : Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're connected").font(.system(size: Theme.Size.s, weight: .semibold))
                Text(welcomeDetail(report, linkedNone: linkedNone)).font(.stSmall).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { withAnimation { justConnected = false } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.borderless).foregroundStyle(Theme.tertiaryText).help("Dismiss")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.success.opacity(0.1)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    func welcomeDetail(_ report: MoodleSyncReport?, linkedNone: Bool) -> String {
        guard let report else { return "Your first import will start in a moment." }
        if let problem = report.errors.first { return "The first import ran into a problem: \(problem)" }
        if linkedNone { return "Link your Moodle courses below and their deadlines, grades and files will come in." }
        var parts: [String] = []
        if report.assignmentsCreated > 0 { parts.append("\(report.assignmentsCreated) deadline\(report.assignmentsCreated == 1 ? "" : "s")") }
        if report.gradesUpdated > 0 { parts.append("\(report.gradesUpdated) grade\(report.gradesUpdated == 1 ? "" : "s")") }
        if report.filesImported > 0 { parts.append("\(report.filesImported) file\(report.filesImported == 1 ? "" : "s")") }
        if parts.isEmpty { return "Everything from Moodle is already here. New work will appear as soon as it's posted." }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "First import brought in \(list). From now on, new work appears on its own."
    }

    var statsRow: some View {
        let s = MoodleSync.stats(store: model.store)
        return HStack(spacing: 10) {
            stat(s.courses, "courses linked")
            stat(s.deadlines, "deadlines")
            stat(s.grades, "grades")
            stat(s.files, "files")
        }
    }

    func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 22, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.stSmall).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
        .animation(.smooth, value: value)
    }

    var syncFooter: some View {
        let store = model.store
        let svc: MoodleService = model.moodle
        let failed = store.setting("moodle_last_status").flatMap { $0.hasPrefix("Sync failed") ? $0 : nil }
        let last = store.setting("moodle_last_sync").flatMap { ISO.parse($0) }
        return HStack(spacing: 10) {
            Image(systemName: failed == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .foregroundStyle(failed == nil ? Theme.tertiaryText : Theme.accent)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let failed {
                    Text(failed).foregroundStyle(Theme.accent).lineLimit(2)
                } else if svc.syncing {
                    Text("Syncing now…")
                } else if let last {
                    Text("Synced \(Self.relative.localizedString(for: last, relativeTo: context.date)) · checks for new work every 3 hours")
                } else {
                    Text("Checks for new work every 3 hours")
                }
            }
            .font(.stSmall).foregroundStyle(Theme.secondaryText)
            Spacer()
            Button(svc.syncing ? "Syncing…" : "Sync now") { Task { await svc.sync(silent: false) } }
                .buttonStyle(QuietButtonStyle()).disabled(svc.syncing)
        }
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()

    var expiredFooter: some View {
        VStack(spacing: 12) {
            Text("Your school ended this connection, which happens when Moodle keys expire. Sign in again and syncing picks up where it left off.")
                .font(.stSmall).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            Button(action: reconnect) {
                Label(reconnecting ? "Opening sign-in…" : model.store.setting("moodle_provider_name").map { "Reconnect with \($0)" } ?? "Reconnect",
                      systemImage: "lock.fill")
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(reconnecting)
        }
    }

    func reconnect() {
        guard let site = model.moodle.site else { return }
        reconnecting = true
        Task {
            let profile = try? await MoodleClient.siteProfile(site: site)
            reconnecting = false
            signIn(MoodleSSOLaunch(site: profile?.site ?? site, profile: profile))
        }
    }

    // MARK: Courses

    @ViewBuilder var coursesSection: some View {
        let mcs = model.moodle.moodleCourses
        let courses = model.store.courses()
        if !mcs.isEmpty {
            let linkedCount = mcs.filter { mc in courses.contains { $0.moodleId == mc.id } }.count
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Courses", trailing: AnyView(
                    Text("\(linkedCount) of \(mcs.count) linked").font(.stSmall).foregroundStyle(Theme.secondaryText)))
                VStack(spacing: 0) {
                    ForEach(Array(mcs.enumerated()), id: \.element.id) { i, mc in
                        if i > 0 { Divider().padding(.leading, 40) }
                        courseRow(mc, local: courses.first { $0.moodleId == mc.id }, courses: courses)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.hairline))
                Text("Deadlines, grades and files come in only for linked courses.").font(.stSmall).foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    func courseRow(_ mc: MoodleCourseInfo, local: Course?, courses: [Course]) -> some View {
        HStack(spacing: 12) {
            Group {
                if let local { CourseDot(color: local.color, size: 10) }
                else { Circle().strokeBorder(Theme.tertiaryText, lineWidth: 1.2).frame(width: 10, height: 10) }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(mc.fullname).font(.stBody).lineLimit(1)
                Text(local == nil ? "Not linked" : mc.shortname).font(.stSmall).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            }
            Spacer(minLength: 12)
            if local == nil {
                Button { create(mc) } label: { Label("Create course", systemImage: "plus") }
                    .buttonStyle(QuietButtonStyle()).help("Add this Moodle course to Study Tracker and link it")
            }
            Picker("", selection: Binding(get: { local?.id ?? 0 }, set: { link(mc, to: $0) })) {
                Text("Not linked").tag(0)
                ForEach(courses) { c in Text(c.displayName).tag(c.id) }
            }
            .labelsHidden().frame(width: 220)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    func link(_ mc: MoodleCourseInfo, to courseId: Int) {
        for var c in model.store.courses() where c.moodleId == mc.id { c.moodleId = nil; _ = try? model.store.saveCourse(c) }
        if courseId != 0, var c = model.store.course(courseId) { c.moodleId = mc.id; _ = try? model.store.saveCourse(c) }
        model.refresh()
    }

    func create(_ mc: MoodleCourseInfo) {
        guard let term = model.store.currentTerm() else { model.show("Add a term first.", error: true); return }
        let code = CourseMatcher.extractCode(mc.shortname) ?? CourseMatcher.extractCode(mc.fullname) ?? mc.shortname
        model.run("Created \(mc.fullname).") {
            _ = try model.store.saveCourse(Course(termId: term.id, code: code, name: mc.fullname, color: "", moodleId: mc.id)); return nil
        }
    }

    // MARK: Sync and security

    var syncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sync")
            Panel {
                switchRow("Download new course files", "New slides and PDFs go into the library, filed by course.", key: "moodle_download_files")
                Divider()
                switchRow("Add deadlines straight to your list", "When off, they wait in the Inbox for you to confirm.", key: "moodle_auto_confirm")
            }
        }
    }

    func switchRow(_ title: String, _ detail: String, key: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.stBody)
                Text(detail).font(.stSmall).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Toggle("", isOn: boolBinding(model, key, default: true)).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    var securitySection: some View {
        let https = model.moodle.site?.scheme == "https"
        let password: (String, String) = switch model.store.setting("moodle_auth_method") {
        case "sso": ("Your password stays with your school", "You signed in on \(schoolName)'s own page. Study Tracker never reads or stores your password.")
        case "key": ("No password involved", "You connected with a security key from Moodle.")
        case "password": ("Password not saved", "Your password was used once to get the key, then discarded.")
        default: ("Password not saved", "Study Tracker keeps only a Moodle key, never your password.")
        }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Security")
            Panel {
                securityRow("key.fill", "Key kept in your Mac's Keychain", "Study Tracker holds a Moodle app key there, never in its database or logs.")
                securityRow("eye.slash.fill", password.0, password.1)
                securityRow("arrow.down.circle.fill", "Read-only", "Study Tracker only reads from Moodle. Nothing is ever submitted, changed or deleted.")
                if https { securityRow("lock.fill", "Encrypted", "Everything travels over HTTPS, straight between this Mac and your school.") }
                Divider().padding(.vertical, 4)
                HStack {
                    Text("Disconnecting deletes the key right away. What's already imported stays.").font(.stSmall).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Disconnect…") { confirmDisconnect = true }.buttonStyle(QuietButtonStyle()).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    func securityRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.success).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: Theme.Size.s, weight: .medium))
                Text(detail).font(.stSmall).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusPill: View {
    var text: String
    var systemImage: String
    var color: Color
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.stSmallStrong)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// Study Tracker and the school side by side: apart until connected, joined by a secure line once they are.
struct MoodleLinkGraphic: View {
    enum LinkState { case idle, connecting, connected, broken }
    var state: LinkState
    var logoURL: URL?
    /// Draw the line in, for the moment a connection is made.
    var animateIn = false
    @State private var drawn: CGFloat = 1
    @State private var flow: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 64, height: 64)
                .accessibilityLabel("Study Tracker")
            connector.frame(width: 140, height: 32)
            schoolTile
        }
        .onAppear {
            guard state == .connected || state == .connecting else { return }
            if animateIn { drawn = 0; withAnimation(.easeOut(duration: 0.8).delay(0.15)) { drawn = 1 } }
        }
        .onChange(of: state) { _, new in
            if new == .connected { drawn = 0; withAnimation(.easeOut(duration: 0.8)) { drawn = 1 } }
        }
    }

    var connector: some View {
        ZStack {
            switch state {
            case .idle:
                HLine().stroke(Theme.tertiaryText, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
            case .connecting:
                // Dashes flowing from the school towards Study Tracker while the first import runs.
                HLine().stroke(Theme.success, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 6], dashPhase: flow))
                    .onAppear { withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) { flow = 12 } }
            case .connected:
                HLine().stroke(Theme.success.opacity(0.18), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                HLine().trim(from: 0, to: drawn).stroke(Theme.success, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            case .broken:
                HLine().stroke(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
            }
            badge
        }
    }

    var badge: some View {
        let (icon, fill, fg): (String, Color, Color) = switch state {
        case .idle: ("link", Color(nsColor: .windowBackgroundColor), Theme.secondaryText)
        case .connecting: ("arrow.down", Theme.success, .white)
        case .connected: ("lock.fill", Theme.success, .white)
        case .broken: ("exclamationmark", Theme.accent, .white)
        }
        return ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(state == .idle ? Color.primary.opacity(0.15) : .clear)
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(fg)
        }
        .frame(width: 32, height: 32)
        .scaleEffect(state == .connected ? 0.7 + 0.3 * drawn : 1)
        .shadow(color: state == .idle ? .clear : fill.opacity(0.35), radius: 6, y: 2)
    }

    /// Logos are drawn for light backgrounds, so the tile stays white in dark mode too.
    var schoolTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.white)
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.08))
            if let logoURL {
                AsyncImage(url: logoURL) { image in
                    image.resizable().interpolation(.high).scaledToFit().padding(10)
                } placeholder: {
                    Image(systemName: "graduationcap.fill").font(.system(size: 24)).foregroundStyle(.black.opacity(0.35))
                }
            } else {
                Image(systemName: "graduationcap.fill").font(.system(size: 24)).foregroundStyle(.black.opacity(0.55))
            }
        }
        .frame(width: logoURL == nil ? 64 : 104, height: 64)
        .accessibilityLabel("Your school's Moodle")
    }
}

private struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: rect.minX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

// MARK: - Sign-in sheet

/// The school's own sign-in page (Microsoft 365, Google, SAML…) in a web view, which catches the token reply the
/// official Moodle app would receive. Cookies live only as long as the sheet, so every sign-in starts fresh.
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
            header
            Divider()
            ZStack {
                MoodleLoginWebView(site: launch.site, passport: launch.passport, signInURL: launch.profile?.providerURL,
                                   loading: $loading, page: $page,
                                   onReply: { reply in
                                       do {
                                           let token = try MoodleClient.token(fromLaunchReply: reply)
                                           withAnimation(.smooth(duration: 0.3)) { signedIn = true }
                                           onToken(token)
                                           DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
                                       } catch { problem = "\(error)" }
                                   },
                                   onFailure: { problem = $0 })
                if signedIn { signedInOverlay.transition(.opacity) }
            }
            Divider()
            Text("Your password goes only to your school's sign-in page. This window closes by itself once you're connected.")
                .font(.stSmall).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 580, height: 740)
    }

    var header: some View {
        let shown = page ?? launch.site
        let secure = shown.scheme == "https"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.system(size: 18)).foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sign in to \(launch.schoolName)").font(.stBodyStrong)
                    Text("Secure sign-in for Study Tracker").font(.stSmall).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            // Like a browser's address bar: which site is asking for the password, and whether the line is encrypted.
            HStack(spacing: 6) {
                Image(systemName: secure ? "lock.fill" : "lock.open.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(secure ? Theme.success : Theme.accent)
                Text(shown.host ?? shown.absoluteString).font(.stSmall).foregroundStyle(Theme.secondaryText).lineLimit(1)
                Spacer()
                if loading && !signedIn { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.stSmall).foregroundStyle(Theme.accent)
            }
        }
        .padding(16)
    }

    var signedInOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.success)
                .symbolEffect(.bounce, value: signedIn)
            Text("Signed in").font(.stHeading)
            Text("Connecting Study Tracker to \(launch.schoolName)…").font(.stBody).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Sites set to "log in within the app" (common with Microsoft 365 through the auth_oidc plugin) refuse the launch page
/// unless the session has only just signed in. So a refusal sends the view to the school's sign-in, and once sign-in
/// finishes, the redirect to the dashboard is swapped for the launch page before anything else loads on the site.
struct MoodleLoginWebView: NSViewRepresentable {
    let site: URL
    let passport: String
    /// The school's single sign-on button, to skip Moodle's login page. Moodle's login page when nil.
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
                // Going to Microsoft or submitting the login form means sign-in has started; clicking around the
                // login page (language, help) does not.
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
                parent.onFailure("Moodle signed you in but still wouldn't give Study Tracker its key. Its reason is below.")
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
            // Cancelled loads and "frame load interrupted" (102) follow our own .cancel above.
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
            // Other app links on the way (Authenticator, mailto…) are ignored.
            guard !replied, url.absoluteString.contains("token=") else { return }
            replied = true
            parent.onReply(url)
        }
    }
}
