import Foundation

public enum JSON {
    /// `round` trims doubles to 3 decimals for human- and model-facing output; storage keeps full precision.
    public static func string(_ value: Any, pretty: Bool = false, round: Bool = false) -> String {
        let sanitized = sanitize(value, round: round)
        guard JSONSerialization.isValidJSONObject(sanitized) || sanitized is String || sanitized is NSNumber || sanitized is NSNull else {
            return "null"
        }
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { opts.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: opts) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    public static func parse(_ s: String?) -> Any? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public static func intArray(_ s: String?) -> [Int] {
        (parse(s) as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") } ?? []
    }

    public static func stringArray(_ s: String?) -> [String] {
        (parse(s) as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Converts Swift values (optionals, Dates, SQLValue, nested) into JSONSerialization-safe values.
    public static func sanitize(_ value: Any?, round: Bool = false) -> Any {
        guard let value else { return NSNull() }
        switch value {
        case let v as SQLValue: return v.jsonValue
        case let v as Date: return ISO.instant(v)
        case let v as LocalDate: return v.string
        case let v as LocalTime: return v.string
        case let v as [String: Any?]: return v.mapValues { sanitize($0, round: round) }
        case let v as [String: Any]: return v.mapValues { sanitize($0, round: round) }
        case let v as [Any?]: return v.map { sanitize($0, round: round) }
        case let v as [Any]: return v.map { sanitize($0, round: round) }
        case let v as Double:
            if v.isNaN || v.isInfinite { return NSNull() }
            return round ? (v * 1000).rounded() / 1000 : v
        case is String, is Int, is Int64, is Bool, is NSNumber, is NSNull: return value
        default:
            let m = Mirror(reflecting: value)
            if m.displayStyle == .optional {
                return m.children.first.map { sanitize($0.value, round: round) } ?? NSNull()
            }
            return String(describing: value)
        }
    }
}
