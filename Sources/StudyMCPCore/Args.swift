import Foundation
import StudyCore

/// Validated access to tool arguments. Every failure becomes an INVALID_ARGUMENT error Claude can act on.
struct Args {
    let raw: [String: Any]
    let path: String

    init(_ raw: [String: Any], path: String = "") { self.raw = raw; self.path = path }

    private func name(_ k: String) -> String { path.isEmpty ? k : "\(path).\(k)" }

    func has(_ k: String) -> Bool { raw[k] != nil && !(raw[k] is NSNull) }

    func optInt(_ k: String) throws -> Int? {
        guard has(k) else { return nil }
        if let n = raw[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            guard d.rounded() == d else { throw ToolError.invalid("\(name(k)) must be an integer.") }
            return n.intValue
        }
        if let s = raw[k] as? String, let i = Int(s) { return i }
        throw ToolError.invalid("\(name(k)) must be an integer.")
    }

    func int(_ k: String) throws -> Int {
        guard let v = try optInt(k) else { throw ToolError.invalid("\(name(k)) is required.") }
        return v
    }

    func optDouble(_ k: String) throws -> Double? {
        guard has(k) else { return nil }
        if let n = raw[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = raw[k] as? String, let d = Double(s) { return d }
        throw ToolError.invalid("\(name(k)) must be a number.")
    }

    func optString(_ k: String, max: Int = 2000) throws -> String? {
        guard has(k) else { return nil }
        guard let s = raw[k] as? String else { throw ToolError.invalid("\(name(k)) must be a string.") }
        if s.count > max { throw ToolError("TOO_LARGE", "\(name(k)) is \(s.count) characters; the limit is \(max).") }
        return s
    }

    func string(_ k: String, max: Int = 2000) throws -> String {
        guard let s = try optString(k, max: max), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("\(name(k)) is required.")
        }
        return s
    }

    func bool(_ k: String, default def: Bool) throws -> Bool {
        guard has(k) else { return def }
        if let b = raw[k] as? Bool { return b }
        if let n = raw[k] as? NSNumber { return n.boolValue }
        throw ToolError.invalid("\(name(k)) must be true or false.")
    }

    func intArray(_ k: String, max: Int = 200) throws -> [Int] {
        guard has(k) else { return [] }
        guard let arr = raw[k] as? [Any] else { throw ToolError.invalid("\(name(k)) must be an array of integers.") }
        if arr.count > max { throw ToolError("TOO_LARGE", "\(name(k)) has \(arr.count) items; the limit is \(max).") }
        return try arr.map { v in
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String, let i = Int(s) { return i }
            throw ToolError.invalid("\(name(k)) must contain only integers.")
        }
    }

    func stringArray(_ k: String, max: Int = 100, itemMax: Int = 200) throws -> [String] {
        guard has(k) else { return [] }
        guard let arr = raw[k] as? [Any] else { throw ToolError.invalid("\(name(k)) must be an array of strings.") }
        if arr.count > max { throw ToolError("TOO_LARGE", "\(name(k)) has \(arr.count) items; the limit is \(max).") }
        return try arr.map { v in
            guard let s = v as? String, s.count <= itemMax else { throw ToolError.invalid("\(name(k)) must contain strings of at most \(itemMax) characters.") }
            return s
        }
    }

    func objects(_ k: String, max: Int, required: Bool = true) throws -> [Args] {
        guard has(k) else {
            if required { throw ToolError.invalid("\(name(k)) is required.") }
            return []
        }
        guard let arr = raw[k] as? [Any] else { throw ToolError.invalid("\(name(k)) must be an array of objects.") }
        if arr.count > max { throw ToolError("TOO_LARGE", "\(name(k)) has \(arr.count) items; the limit is \(max) per call.", hint: "Split into several calls.") }
        return try arr.enumerated().map { i, v in
            guard let d = v as? [String: Any] else { throw ToolError.invalid("\(name(k))[\(i)] must be an object.") }
            return Args(d, path: "\(name(k))[\(i)]")
        }
    }

    func oneOf(_ k: String, _ allowed: [String], default def: String? = nil) throws -> String? {
        guard let v = try optString(k, max: 60) else { return def }
        guard allowed.contains(v) else { throw ToolError.invalid("\(name(k)) must be one of \(allowed.joined(separator: ", ")).") }
        return v
    }

    func date(_ k: String) throws -> LocalDate? {
        guard let s = try optString(k, max: 40) else { return nil }
        guard let d = LocalDate(s) else { throw ToolError.invalid("\(name(k)) must be a date like 2026-10-06.") }
        return d
    }
}

/// JSON Schema builders for tool definitions.
enum Schema {
    static func object(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        var d: [String: Any] = ["type": "object", "properties": props, "additionalProperties": false]
        if !required.isEmpty { d["required"] = required }
        return d
    }
    static func int(_ desc: String, min: Int? = nil, max: Int? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "integer", "description": desc]
        if let min { d["minimum"] = min }
        if let max { d["maximum"] = max }
        return d
    }
    static func number(_ desc: String) -> [String: Any] { ["type": "number", "description": desc] }
    static func string(_ desc: String, max: Int? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "string", "description": desc]
        if let max { d["maxLength"] = max }
        return d
    }
    static func bool(_ desc: String) -> [String: Any] { ["type": "boolean", "description": desc] }
    static func enumString(_ values: [String], _ desc: String) -> [String: Any] { ["type": "string", "enum": values, "description": desc] }
    static func array(_ items: [String: Any], _ desc: String, max: Int? = nil, min: Int? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "array", "items": items, "description": desc]
        if let max { d["maxItems"] = max }
        if let min { d["minItems"] = min }
        return d
    }
    static func intArray(_ desc: String, min: Int? = nil) -> [String: Any] { array(["type": "integer"], desc, min: min) }
}
