import Foundation

/// Read-only client for Moodle's mobile web services (the same API the official Moodle app uses).
/// The token lives in the Keychain. Nothing is written back to Moodle.
public struct MoodleClient {
    public let site: URL
    public let token: String
    public var session: URLSession = .shared

    public init(site: URL, token: String) { self.site = site; self.token = token }

    public struct MoodleError: Error, CustomStringConvertible {
        public let message: String
        /// Moodle's own error code, e.g. "invalidtoken" once the school ends the connection.
        public var code: String?
        public init(message: String, code: String? = nil) { self.message = message; self.code = code }
        public var description: String { message }
    }

    public static func normalizeSite(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        for suffix in ["/login/index.php", "/my", "/my/index.php", "/course/view.php"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return URL(string: t)
    }

    /// Exchanges a username and password for a mobile-app token. The password is never stored.
    public static func requestToken(site: URL, username: String, password: String, session: URLSession = .shared) async throws -> String {
        var req = URLRequest(url: site.appendingPathComponent("login/token.php"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["username": username, "password": password, "service": "moodle_mobile_app"]).data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MoodleError(message: "Moodle did not answer as expected. Check the site address.")
        }
        if let token = obj["token"] as? String { return token }
        let msg = obj["error"] as? String ?? "Moodle refused the sign-in."
        throw MoodleError(message: msg + " If your school signs in with Microsoft 365 or another single sign-on, choose \"Microsoft 365 / SSO\" instead.")
    }

    /// What a site says about itself before anyone signs in: the same call the official app makes first.
    public static func siteProfile(site: URL, session: URLSession = .shared) async throws -> MoodleSiteProfile {
        var comps = URLComponents(url: site.appendingPathComponent("lib/ajax/service-nologin.php"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "info", value: "tool_mobile_get_public_config")]
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"[{"index":0,"methodname":"tool_mobile_get_public_config","args":{}}]"#.utf8)
        let (data, _) = try await session.data(for: req)
        guard let profile = MoodleSiteProfile(publicConfig: data, site: site) else {
            throw MoodleError(message: "No Moodle site answered at this address.")
        }
        return profile
    }

    /// The page the official Moodle app opens for single sign-on (Microsoft 365, Google, SAML…). Once the school's
    /// sign-in finishes, Moodle redirects to `moodlemobile://token=<base64>`, which `token(fromLaunchReply:)` reads.
    public static func launchURL(site: URL, passport: String) -> URL {
        var comps = URLComponents(url: site.appendingPathComponent("admin/tool/mobile/launch.php"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "service", value: "moodle_mobile_app"),
                            URLQueryItem(name: "passport", value: passport),
                            URLQueryItem(name: "urlscheme", value: "moodlemobile")]
        return comps.url!
    }

    /// Whether a page is part of signing in: another host (Microsoft…), or Moodle's login, auth plugin, MFA or launch
    /// pages. Any other page on the site is where Moodle sends you once sign-in has finished.
    public static func isSignInPage(_ url: URL, site: URL) -> Bool {
        guard url.host?.lowercased() == site.host?.lowercased() else { return true }
        var path = url.path
        if !site.path.isEmpty, path.hasPrefix(site.path) { path = String(path.dropFirst(site.path.count)) }
        return ["/login", "/auth", "/admin/tool/mfa", "/admin/tool/mobile/launch.php"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Reads the web service token from the launch reply. Its payload is base64 of `signature:::token[:::privatetoken]`.
    /// The scheme isn't checked: a school with a branded app can force its own scheme in place of `moodlemobile`.
    public static func token(fromLaunchReply url: URL) throws -> String {
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard let start = text.range(of: "token=") else { throw MoodleError(message: "Moodle's sign-in reply had no token.") }
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        var b64 = String(text[start.upperBound...].unicodeScalars.prefix { alphabet.contains($0) })
        b64 = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let payload = String(data: data, encoding: .utf8) else {
            throw MoodleError(message: "Moodle's sign-in reply could not be read.")
        }
        let parts = payload.components(separatedBy: ":::")
        guard parts.count >= 2, !parts[1].isEmpty, parts[1].allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw MoodleError(message: "Moodle's sign-in reply had no token.")
        }
        return parts[1]
    }

    static func form(_ params: [String: Any]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        var parts: [String] = []
        func add(_ key: String, _ value: Any) {
            switch value {
            case let arr as [Any]: for (i, v) in arr.enumerated() { add("\(key)[\(i)]", v) }
            case let dict as [String: Any]: for (k, v) in dict { add("\(key)[\(k)]", v) }
            default: parts.append("\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\("\(value)".addingPercentEncoding(withAllowedCharacters: allowed) ?? "")")
            }
        }
        for (k, v) in params.sorted(by: { $0.key < $1.key }) { add(k, v) }
        return parts.joined(separator: "&")
    }

    public func call(_ function: String, _ params: [String: Any] = [:]) async throws -> Any {
        var req = URLRequest(url: site.appendingPathComponent("webservice/rest/server.php"), timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params
        all["wstoken"] = token
        all["wsfunction"] = function
        all["moodlewsrestformat"] = "json"
        req.httpBody = Self.form(all).data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MoodleError(message: "Moodle answered \(http.statusCode) for \(function).")
        }
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let d = obj as? [String: Any], d["exception"] != nil {
            let code = d["errorcode"] as? String ?? ""
            if code == "invalidtoken" { throw MoodleError(message: "The Moodle token is no longer valid. Sign in again in Settings.", code: code) }
            throw MoodleError(message: (d["message"] as? String ?? "Moodle error") + " (\(function))")
        }
        return obj
    }

    public func download(_ fileURL: String) async throws -> Data {
        guard var comps = URLComponents(string: fileURL) else { throw MoodleError(message: "Bad file address.") }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token))
        comps.queryItems = items
        guard let url = comps.url else { throw MoodleError(message: "Bad file address.") }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw MoodleError(message: "Download failed (\(http.statusCode)).") }
        return data
    }
}

/// A site's name, logo and sign-in button, from `tool_mobile_get_public_config`.
public struct MoodleSiteProfile: Equatable {
    /// The site's own address (wwwroot), which may differ from what was typed.
    public var site: URL
    public var name: String
    public var logoURL: URL?
    /// The school's single sign-on button (e.g. "Microsoft Office 365") when there is exactly one.
    public var providerName: String?
    /// Where that button leads. Only kept when it is on the site itself.
    public var providerURL: URL?
    /// Whether the school lets the Moodle app (and so Study Tracker) connect at all.
    public var appAccess: Bool

    public init?(publicConfig data: Data, site: URL) {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = arr.first,
              (first["error"] as? Bool) != true, let d = first["data"] as? [String: Any] else { return nil }
        func url(_ key: String) -> URL? { (d[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        func on(_ key: String) -> Bool { (d[key] as? NSNumber)?.boolValue ?? true }
        let root = url("httpswwwroot") ?? url("wwwroot") ?? site
        let providers = d["identityproviders"] as? [[String: Any]] ?? []
        let only = providers.count == 1 ? providers[0] : nil
        self.site = root
        name = MoodleClient.stripHTML(d["sitename"] as? String) ?? root.host ?? "Moodle"
        logoURL = url("compactlogourl") ?? url("logourl")
        providerName = only?["name"] as? String
        providerURL = (only?["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.host?.lowercased() == root.host?.lowercased() ? $0 : nil }
        appAccess = on("enablewebservices") && on("enablemobilewebservice")
    }
}

public struct MoodleCourseInfo: Hashable {
    public var id: Int; public var shortname: String; public var fullname: String
    /// Course dates from Moodle, when the school sets them (and keeps them up to date, which not every school does).
    public var start: Date?; public var end: Date?
    /// When the student last opened the course in Moodle.
    public var lastAccess: Date?
    public init(id: Int, shortname: String, fullname: String, start: Date? = nil, end: Date? = nil, lastAccess: Date? = nil) {
        self.id = id; self.shortname = shortname; self.fullname = fullname; self.start = start; self.end = end; self.lastAccess = lastAccess
    }

    init?(json d: [String: Any]) {
        guard let id = (d["id"] as? NSNumber)?.intValue else { return nil }
        func date(_ k: String) -> Date? { ((d[k] as? NSNumber)?.doubleValue).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
        self.init(id: id, shortname: MoodleClient.stripHTML(d["shortname"] as? String) ?? "", fullname: MoodleClient.stripHTML(d["fullname"] as? String) ?? "",
                  start: date("startdate"), end: date("enddate"), lastAccess: date("lastaccess"))
    }
}

extension MoodleClient {
    /// The Keychain account holding the Moodle token.
    public static let tokenAccount = "moodle-token"

    /// Moodle's HTML (names, descriptions) as plain text.
    public static func stripHTML(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let noTags = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let t = noTags.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(4000))
    }
}
