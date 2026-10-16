import Foundation

/// JSON that keeps object key order. Used for provider payloads and for editing other apps' config files without
/// reordering them (JSONSerialization loses order). Comments and trailing commas are rejected as `.jsonc`, so a
/// commented file is never rewritten and stripped of its comments.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        get { if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }; return nil }
        set {
            guard case .object(var pairs) = self else { return }
            if let i = pairs.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { pairs[i].1 = v } else { pairs.remove(at: i) }
            } else if let v = newValue {
                pairs.append((key, v))
            }
            self = .object(pairs)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { number.flatMap { $0.rounded() == $0 ? Int($0) : nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [(String, JSONValue)]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    // MARK: Bridging to Foundation values

    /// From JSONSerialization-style values. Dictionary keys are sorted, since a Swift dictionary has no order.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let v as JSONValue: self = v
        // NSNumber first: on Apple platforms `NSNumber(1) as? Bool` succeeds, so a Bool case would swallow numbers.
        case let n as NSNumber: self = CFGetTypeIDIsBool(n) ? .bool(n.boolValue) : .number(n.doubleValue)
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let a as [Any?]: self = .array(a.map { JSONValue(any: $0) })
        case let d as [String: Any]: self = .object(d.keys.sorted().map { ($0, JSONValue(any: d[$0])) })
        case let d as [String: Any?]: self = .object(d.keys.sorted().map { ($0, JSONValue(any: d[$0] ?? nil)) })
        default: self = .string("\(value!)")
        }
    }

    /// To JSONSerialization-style values (order is lost).
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return Dictionary(o.map { ($0.0, $0.1.any) }, uniquingKeysWith: { _, b in b })
        }
    }

    // MARK: Parsing

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case jsonc, invalid(String)
        public var description: String {
            switch self {
            case .jsonc: return "The file has comments or trailing commas (JSONC)."
            case .invalid(let m): return "Not valid JSON: \(m)"
            }
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(Array(text.utf8))
        p.skipSpace()
        let v = try p.value()
        p.skipSpace()
        guard p.i == p.b.count else { throw ParseError.invalid("extra text at offset \(p.i)") }
        return v
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        guard let s = String(data: data, encoding: .utf8) else { throw ParseError.invalid("not UTF-8") }
        return try parse(s)
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b; if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 } }

        mutating func skipSpace() {
            while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
        }

        func peekComment() -> Bool { i + 1 < b.count && b[i] == 0x2F && (b[i + 1] == 0x2F || b[i + 1] == 0x2A) }

        mutating func value() throws -> JSONValue {
            if peekComment() { throw ParseError.jsonc }
            guard i < b.count else { throw ParseError.invalid("unexpected end") }
            switch b[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw ParseError.invalid("bad literal at \(i)") }
            i += u.count
        }

        mutating func object() throws -> JSONValue {
            i += 1
            var pairs: [(String, JSONValue)] = []
            skipSpace()
            if peekComment() { throw ParseError.jsonc }
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipSpace()
                if peekComment() { throw ParseError.jsonc }
                guard i < b.count else { throw ParseError.invalid("unterminated object") }
                if b[i] == UInt8(ascii: "}") { throw ParseError.jsonc } // trailing comma
                guard b[i] == UInt8(ascii: "\"") else { throw ParseError.invalid("expected key at \(i)") }
                let key = try string()
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw ParseError.invalid("expected : at \(i)") }
                i += 1
                skipSpace()
                pairs.append((key, try value()))
                skipSpace()
                if peekComment() { throw ParseError.jsonc }
                guard i < b.count else { throw ParseError.invalid("unterminated object") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw ParseError.invalid("expected , or } at \(i)")
            }
        }

        mutating func array() throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipSpace()
            if peekComment() { throw ParseError.jsonc }
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipSpace()
                if peekComment() { throw ParseError.jsonc }
                guard i < b.count else { throw ParseError.invalid("unterminated array") }
                if b[i] == UInt8(ascii: "]") { throw ParseError.jsonc } // trailing comma
                items.append(try value())
                skipSpace()
                if peekComment() { throw ParseError.jsonc }
                guard i < b.count else { throw ParseError.invalid("unterminated array") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw ParseError.invalid("expected , or ] at \(i)")
            }
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { break }
                    switch b[i] {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xD800...0xDBFF).contains(scalar), i + 2 < b.count, b[i + 1] == UInt8(ascii: "\\"), b[i + 2] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar) ?? "?")).utf8))
                    default: out.append(b[i])
                    }
                    i += 1
                } else {
                    out.append(c); i += 1
                }
            }
            throw ParseError.invalid("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 < b.count, let v = UInt32(String(decoding: b[(i + 1)...(i + 4)], as: UTF8.self), radix: 16) else {
                throw ParseError.invalid("bad \\u escape at \(i)")
            }
            i += 4
            return v
        }

        mutating func number() throws -> Double {
            let start = i
            while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
            guard i > start, let d = Double(String(decoding: b[start..<i], as: UTF8.self)) else { throw ParseError.invalid("bad value at \(start)") }
            return d
        }
    }

    // MARK: Serializing

    /// Compact by default; `indent` pretty-prints with that many spaces (2 matches what most apps write).
    public func serialized(indent: Int? = nil) -> String {
        var out = ""
        write(into: &out, indent: indent, level: 0)
        return out
    }

    private func write(into out: inout String, indent: Int?, level: Int) {
        let nl = indent == nil ? "" : "\n"
        func pad(_ l: Int) -> String { indent.map { String(repeating: " ", count: $0 * l) } ?? "" }
        switch self {
        case .null: out += "null"
        case .bool(let v): out += v ? "true" : "false"
        case .number(let n):
            if n.rounded() == n && abs(n) < 1e15 { out += String(Int(n)) } else { out += String(n) }
        case .string(let s): out += JSONValue.quote(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (k, v) in a.enumerated() {
                out += pad(level + 1)
                v.write(into: &out, indent: indent, level: level + 1)
                out += (k < a.count - 1 ? "," : "") + nl
            }
            out += pad(level) + "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (k, (key, v)) in o.enumerated() {
                out += pad(level + 1) + JSONValue.quote(key) + (indent == nil ? ":" : ": ")
                v.write(into: &out, indent: indent, level: level + 1)
                out += (k < o.count - 1 ? "," : "") + nl
            }
            out += pad(level) + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements) }
}

private func CFGetTypeIDIsBool(_ v: Any?) -> Bool {
    #if canImport(ObjectiveC)
    guard let n = v as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
    #else
    return v is Bool
    #endif
}
