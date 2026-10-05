import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// "Sign in with OpenRouter": OAuth PKCE that ends with a key the student controls (and can revoke on openrouter.ai),
/// so nobody copies keys around. The app catches the callback on a loopback address.
public struct OpenRouterAuth: Sendable {
    public let verifier: String
    public let challenge: String
    public let method: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        verifier = Self.base64url(Data(bytes))
        #if canImport(CryptoKit)
        challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        method = "S256"
        #else
        challenge = verifier
        method = "plain"
        #endif
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public func authorizeURL(callback: URL) -> URL {
        var c = URLComponents(string: "https://openrouter.ai/auth")!
        c.queryItems = [URLQueryItem(name: "callback_url", value: callback.absoluteString),
                        URLQueryItem(name: "code_challenge", value: challenge),
                        URLQueryItem(name: "code_challenge_method", value: method)]
        return c.url!
    }

    /// Exchanges the code from the callback for the student's key.
    public func exchange(code: String, transport: HTTPTransport = URLSessionTransport()) async throws -> String {
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(JSONValue.object([("code", .string(code)), ("code_verifier", .string(verifier)), ("code_challenge_method", .string(method))]).serialized().utf8)
        let (data, http): (Data, HTTPURLResponse)
        do { (data, http) = try await transport.data(for: r) } catch { throw HTTPErrors.mapTransport(error, provider: Catalog.openRouter) }
        guard (200..<300).contains(http.statusCode), let key = (try? JSONValue.parse(data))?["key"]?.string, !key.isEmpty else {
            throw AIError.auth("OpenRouter sign-in didn't finish: \(HTTPErrors.message(data).prefix(160))")
        }
        return key
    }
}
