import Foundation

/// Makes a model's SVG drawing safe to show and fit to the theme. Only plain shapes, lines and text survive: no
/// scripts, no embedded HTML, no images, no links outside the drawing, no event handlers and no styles that load
/// anything. Every colour becomes the theme's text colour, so a diagram reads like a clean pen drawing in light and dark.
/// Returns nil when nothing safe is left, and the page shows what to draw instead.
public enum SVGSanitizer {
    public static let maxBytes = 20_000
    static let maxElements = 400

    static let elements: Set<String> = ["svg", "g", "path", "line", "polyline", "polygon", "rect", "circle", "ellipse",
                                        "text", "tspan", "defs", "marker", "title", "desc"]
    static let attributes: Set<String> = [
        "viewBox", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "d", "points", "transform",
        "fill", "stroke", "stroke-width", "stroke-dasharray", "stroke-linecap", "stroke-linejoin", "fill-opacity", "stroke-opacity",
        "opacity", "font-size", "font-weight", "font-style", "text-anchor", "dominant-baseline", "dx", "dy",
        "marker-start", "marker-mid", "marker-end", "markerWidth", "markerHeight", "refX", "refY", "orient", "markerUnits", "id",
    ]
    static let colourAttributes: Set<String> = ["fill", "stroke"]

    public static func sanitize(_ svg: String) -> String? {
        guard svg.utf8.count <= maxBytes * 2, let data = svg.data(using: .utf8), let root = XMLTree.parse(data),
              root.name.lowercased().hasSuffix("svg") else { return nil }
        var count = 0
        guard let body = node(root, isRoot: true, count: &count), count > 1 else { return nil }
        return body.utf8.count <= maxBytes ? body : nil
    }

    static func node(_ n: XNode, isRoot: Bool = false, count: inout Int) -> String? {
        let name = n.name.split(separator: ":").last.map(String.init) ?? n.name
        guard elements.contains(name), count < maxElements else { return nil }
        count += 1
        var attrs: [(String, String)] = []
        for (k, v) in n.attributes.sorted(by: { $0.key < $1.key }) {
            guard attributes.contains(k), let value = safeValue(k, v) else { continue }
            if isRoot && (k == "width" || k == "height") { continue }
            attrs.append((k, value))
        }
        if isRoot {
            attrs.insert(("xmlns", "http://www.w3.org/2000/svg"), at: 0)
            if !attrs.contains(where: { $0.0 == "viewBox" }), let w = n.attributes["width"].flatMap(number), let h = n.attributes["height"].flatMap(number) {
                attrs.append(("viewBox", "0 0 \(w) \(h)"))
            }
        }
        let open = "<\(name)" + attrs.map { " \($0.0)=\"\(escape($0.1))\"" }.joined()
        let text = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let children = n.children.compactMap { node($0, count: &count) }
        if children.isEmpty && text.isEmpty { return open + "/>" }
        return open + ">" + escape(text) + children.joined() + "</\(name)>"
    }

    /// Nil drops the attribute. Colours become the theme's text colour; references may only point inside the drawing.
    static func safeValue(_ key: String, _ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = v.lowercased()
        if lower.contains("javascript") || lower.contains("expression") || lower.contains("<") || lower.contains("@import") { return nil }
        if colourAttributes.contains(key) {
            if lower == "none" || lower == "transparent" { return "none" }
            if lower.hasPrefix("url(") { return lower.range(of: #"^url\(#[a-z0-9_\-]+\)$"#, options: .regularExpression) != nil ? v : "currentColor" }
            return "currentColor"
        }
        if key.hasPrefix("marker-") {
            return lower.range(of: #"^url\(#[a-z0-9_\-]+\)$"#, options: .regularExpression) != nil ? v : nil
        }
        if lower.contains("url(") { return nil }
        return String(v.prefix(4_000))
    }

    static func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
