import Foundation

/// Turns a JSON Schema into what strict structured-output modes accept.
public enum JSONSchemaTools {
    /// Removes keywords strict structured-output modes reject (numeric and length bounds) and closes every object.
    public static func strictCompatible(_ s: JSONValue) -> JSONValue {
        switch s {
        case .object(let pairs):
            let dropped: Set = ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "pattern", "format"]
            var out = pairs.filter { !dropped.contains($0.0) }.map { key, value -> (String, JSONValue) in
                // "properties" maps names to schemas: the names themselves are never keywords to drop.
                if key == "properties", case .object(let props) = value { return (key, .object(props.map { ($0.0, strictCompatible($0.1)) })) }
                return (key, strictCompatible(value))
            }
            if out.contains(where: { $0.0 == "type" && $0.1 == "object" }), !out.contains(where: { $0.0 == "additionalProperties" }) {
                out.append(("additionalProperties", false))
            }
            return .object(out)
        case .array(let a): return .array(a.map(strictCompatible))
        default: return s
        }
    }
}
