import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The network seam, so provider tests run against recorded responses instead of real services.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Server-sent events arrive line by line. Platforms without byte streaming get the whole body split into lines.
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse("not an HTTP response") }
        return (data, http)
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        #if canImport(FoundationNetworking)
        let (data, http) = try await self.data(for: request)
        let all = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return (http, AsyncThrowingStream { c in all.forEach { c.yield($0) }; c.finish() })
        #else
        let (bytes, resp) = try await session.bytes(for: request)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse("not an HTTP response") }
        if !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 64_000 { break } }
            throw HTTPErrors.map(status: http.statusCode, headers: http, body: body, provider: request.url?.host ?? "the service", model: nil)
        }
        let stream = AsyncThrowingStream<String, Error> { c in
            let task = Task {
                do {
                    for try await line in bytes.lines { c.yield(line) }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
        #endif
    }
}

/// Maps HTTP failures from any provider onto `AIError`.
public enum HTTPErrors {
    public static func message(_ body: Data) -> String {
        guard let v = try? JSONValue.parse(body) else { return String(decoding: body.prefix(300), as: UTF8.self) }
        if let m = v["error"]?["message"]?.string { return m }
        if let m = v["error"]?.string { return m }
        if let m = v["message"]?.string { return m }
        if let m = v["detail"]?.string { return m }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }

    public static func map(status: Int, headers: HTTPURLResponse, body: Data, provider: String, model: String?) -> AIError {
        let msg = message(body)
        let lower = msg.lowercased()
        switch status {
        case 401, 403:
            return .auth("\(provider) rejected the key (\(status)). Check it in Settings › AI. \(msg.prefix(160))")
        case 402:
            return .quotaExhausted(message: "Your \(provider) credits have run out.", resetAt: nil)
        case 404 where lower.contains("model") || model != nil && lower.contains(model!.lowercased()):
            return .modelGone(model ?? "")
        case 408, 409, 425:
            return .rateLimited(retryAfter: retryAfter(headers))
        case 429:
            if lower.contains("per-day") || lower.contains("per day") || lower.contains("daily") || lower.contains("quota") || lower.contains("credits") {
                return .quotaExhausted(message: "\(provider) limit reached: \(msg.prefix(160))", resetAt: resetDate(headers))
            }
            return .rateLimited(retryAfter: retryAfter(headers))
        case 400, 413, 422:
            if lower.contains("context") || lower.contains("too long") || lower.contains("too many tokens") || lower.contains("maximum") && lower.contains("token") {
                return .contextTooLong
            }
            if lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist") || lower.contains("not available")) {
                return .modelGone(model ?? "")
            }
            return .badResponse("\(status): \(msg.prefix(240))")
        case 500...599:
            return status == 529 || status == 503 ? .rateLimited(retryAfter: retryAfter(headers)) : .network("\(provider) is having problems (HTTP \(status)).")
        default:
            return .badResponse("\(status): \(msg.prefix(240))")
        }
    }

    static func retryAfter(_ h: HTTPURLResponse) -> TimeInterval? {
        if let v = h.value(forHTTPHeaderField: "retry-after"), let s = TimeInterval(v) { return s }
        return nil
    }

    /// X-RateLimit-Reset in milliseconds (OpenRouter) or seconds since 1970.
    static func resetDate(_ h: HTTPURLResponse) -> Date? {
        guard let v = h.value(forHTTPHeaderField: "x-ratelimit-reset"), let n = Double(v) else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }

    /// A local server that isn't running fails with "connection refused" rather than an HTTP status.
    public static func mapTransport(_ error: Error, provider: ProviderDescriptor) -> AIError {
        if let e = error as? AIError { return e }
        if error is CancellationError { return .canceled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled: return .canceled
            case NSURLErrorCannotConnectToHost where provider.runsLocally, NSURLErrorCannotFindHost where provider.runsLocally:
                return .unavailable("\(provider.name) isn't running. Start it, load a model, and try again.")
            case NSURLErrorNotConnectedToInternet: return .network("You're offline.")
            case NSURLErrorTimedOut: return .network("\(provider.name) took too long to answer.")
            default: break
            }
        }
        return .network(error.localizedDescription)
    }
}

extension Data {
    var base64: String { base64EncodedString() }
}
