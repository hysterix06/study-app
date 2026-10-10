import Foundation

/// A diagram described as data, not drawn as pictures: the AI says *what* is on it (curves S and D, equilibrium E,
/// a shaded surplus, a shift from D to D′) and the app decides *how* to draw it. A supply-and-demand graph is about
/// 150 tokens this way instead of thousands as SVG, it can't carry scripts, and it follows the app's theme and dark
/// mode. One layout feeds every renderer: the SwiftUI view in the app and the SVG used for exports.
///
/// Two kinds:
/// - `graph`: an x-y graph on a 0-10 grid (economics graphs, cost curves, any labelled chart without real data).
/// - `flow`: 2-8 steps joined by arrows, optionally a cycle (processes, cause and effect).
public struct Diagram: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case graph, flow }

    public struct Curve: Codable, Hashable, Sendable {
        public var label: String?
        public var points: [DPoint]
        public var dashed: Bool
        public var smooth: Bool
        public init(label: String?, points: [DPoint], dashed: Bool = false, smooth: Bool = false) {
            self.label = label; self.points = points; self.dashed = dashed; self.smooth = smooth
        }
    }

    /// A labelled point. `xTick`/`yTick` draw dashed guides down and across to the axes, labelled there (Q*, P*).
    public struct Marker: Codable, Hashable, Sendable {
        public var label: String?
        public var at: DPoint
        public var xTick: String?
        public var yTick: String?
        public init(label: String?, at: DPoint, xTick: String? = nil, yTick: String? = nil) { self.label = label; self.at = at; self.xTick = xTick; self.yTick = yTick }
        enum CodingKeys: String, CodingKey { case label, at, xTick = "x_tick", yTick = "y_tick" }
    }

    /// A shaded region, such as consumer surplus or deadweight loss.
    public struct Area: Codable, Hashable, Sendable {
        public var label: String?
        public var points: [DPoint]
        public init(label: String?, points: [DPoint]) { self.label = label; self.points = points }
    }

    /// A shift or movement, such as D → D′.
    public struct Arrow: Codable, Hashable, Sendable {
        public var label: String?
        public var from: DPoint
        public var to: DPoint
        public init(label: String?, from: DPoint, to: DPoint) { self.label = label; self.from = from; self.to = to }
    }

    public var kind: Kind
    public var title: String?
    public var xLabel: String?
    public var yLabel: String?
    /// The grid runs from 0 to these values; the AI is asked for 0-10.
    public var xMax: Double
    public var yMax: Double
    public var curves: [Curve]
    public var markers: [Marker]
    public var areas: [Area]
    public var arrows: [Arrow]
    public var steps: [String]
    public var cycle: Bool

    public init(kind: Kind, title: String? = nil, xLabel: String? = nil, yLabel: String? = nil, xMax: Double = 10, yMax: Double = 10,
                curves: [Curve] = [], markers: [Marker] = [], areas: [Area] = [], arrows: [Arrow] = [], steps: [String] = [], cycle: Bool = false) {
        self.kind = kind; self.title = title; self.xLabel = xLabel; self.yLabel = yLabel; self.xMax = xMax; self.yMax = yMax
        self.curves = curves; self.markers = markers; self.areas = areas; self.arrows = arrows; self.steps = steps; self.cycle = cycle
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, xLabel = "x_label", yLabel = "y_label", xMax = "x_max", yMax = "y_max", curves, markers, areas, arrows, steps, cycle
    }

    // MARK: Limits

    public static let maxCurves = 6, maxCurvePoints = 24, maxMarkers = 8, maxAreas = 4, maxArrows = 6, maxSteps = 8
    public static let maxLabel = 24, maxStep = 60, maxTitle = 80

    /// JSON Schema for the loose form the AI writes (see `parse`).
    public static var jsonSchema: [String: Any] {
        let str: [String: Any] = ["type": "string"]
        let point: [String: Any] = ["type": "array", "items": ["type": "number"], "description": "[x, y] on the 0-10 grid"]
        let points: [String: Any] = ["type": "array", "items": point]
        func list(_ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "array", "items": ["type": "object", "properties": props, "required": required] as [String: Any]]
        }
        return [
            "type": "object",
            "description": "Only when the section explains a graph or a process. graph: x-y graph on a 0-10 grid. flow: 2-8 short steps.",
            "properties": [
                "kind": ["type": "string", "enum": ["graph", "flow"]],
                "title": str, "x_label": str, "y_label": str,
                "curves": list(["label": str, "points": points, "dashed": ["type": "boolean"],
                                "smooth": ["type": "boolean", "description": "true for curved lines through 3+ points"]], ["label", "points"]),
                "points": list(["label": str, "x": ["type": "number"], "y": ["type": "number"],
                                "x_tick": ["type": "string", "description": "Axis label such as Q*; draws a guide to the axis"],
                                "y_tick": ["type": "string", "description": "Axis label such as P*"]], ["label", "x", "y"]),
                "areas": list(["label": str, "points": points], ["label", "points"]),
                "arrows": list(["label": str, "from": point, "to": point], ["from", "to"]),
                "steps": ["type": "array", "items": str],
                "cycle": ["type": "boolean", "description": "flow: the last step leads back to the first"],
            ] as [String: Any],
            "required": ["kind"],
        ]
    }

    // MARK: Reading what an AI wrote

    /// Reads a diagram from loosely typed JSON (an AI answer or an MCP argument), keeping what is valid and saying
    /// what was dropped. Returns nil when nothing drawable is left.
    public static func parse(_ any: Any?) -> (diagram: Diagram?, warnings: [String]) {
        guard let d = any as? [String: Any] else { return (nil, any == nil || any is NSNull ? [] : ["A diagram wasn't an object, so it was left out."]) }
        var warnings: [String] = []
        let kind = Kind(rawValue: (d["kind"] as? String ?? "").lowercased()) ?? (d["steps"] != nil && d["curves"] == nil ? .flow : .graph)
        let xMax = num(d["x_max"]).flatMap { $0 > 0 && $0 <= 1e6 ? $0 : nil } ?? 10
        let yMax = num(d["y_max"]).flatMap { $0 > 0 && $0 <= 1e6 ? $0 : nil } ?? 10
        func pt(_ v: Any?) -> DPoint? {
            if let a = v as? [Any], a.count >= 2, let x = num(a[0]), let y = num(a[1]) { return clamp(DPoint(x, y)) }
            if let o = v as? [String: Any], let x = num(o["x"]), let y = num(o["y"]) { return clamp(DPoint(x, y)) }
            return nil
        }
        func clamp(_ p: DPoint) -> DPoint? {
            guard p.x.isFinite, p.y.isFinite else { return nil }
            return DPoint(min(max(p.x, 0), xMax * 1.1), min(max(p.y, 0), yMax * 1.1))
        }
        var out = Diagram(kind: kind, title: text(d["title"], max: maxTitle), xLabel: text(d["x_label"], max: maxLabel), yLabel: text(d["y_label"], max: maxLabel),
                          xMax: xMax, yMax: yMax)
        switch kind {
        case .graph:
            for c in (d["curves"] as? [Any] ?? []).prefix(maxCurves) {
                guard let c = c as? [String: Any] else { continue }
                let pts = (c["points"] as? [Any] ?? []).prefix(maxCurvePoints).compactMap(pt)
                guard pts.count >= 2 else { warnings.append("A curve with fewer than two points was left out."); continue }
                out.curves.append(Curve(label: text(c["label"], max: maxLabel), points: pts, dashed: c["dashed"] as? Bool ?? false,
                                        smooth: (c["smooth"] as? Bool ?? false) && pts.count >= 3))
            }
            for m in (d["points"] as? [Any] ?? d["markers"] as? [Any] ?? []).prefix(maxMarkers) {
                guard let m = m as? [String: Any], let p = pt(m["at"]) ?? pt(m) else { continue }
                out.markers.append(Marker(label: text(m["label"], max: maxLabel), at: p, xTick: text(m["x_tick"], max: maxLabel), yTick: text(m["y_tick"], max: maxLabel)))
            }
            for a in (d["areas"] as? [Any] ?? []).prefix(maxAreas) {
                guard let a = a as? [String: Any] else { continue }
                let pts = (a["points"] as? [Any] ?? []).prefix(maxCurvePoints).compactMap(pt)
                guard pts.count >= 3 else { warnings.append("A shaded area with fewer than three corners was left out."); continue }
                out.areas.append(Area(label: text(a["label"], max: maxLabel), points: pts))
            }
            for a in (d["arrows"] as? [Any] ?? []).prefix(maxArrows) {
                guard let a = a as? [String: Any], let f = pt(a["from"]), let t = pt(a["to"]), f != t else { continue }
                out.arrows.append(Arrow(label: text(a["label"], max: maxLabel), from: f, to: t))
            }
            if out.curves.isEmpty && out.markers.isEmpty && out.areas.isEmpty { return (nil, warnings + ["A graph had nothing to draw, so it was left out."]) }
        case .flow:
            out.steps = (d["steps"] as? [Any] ?? []).compactMap { text($0, max: maxStep) }.prefix(maxSteps).map { $0 }
            out.cycle = d["cycle"] as? Bool ?? false
            guard out.steps.count >= 2 else { return (nil, warnings + ["A flow needs at least two steps, so it was left out."]) }
        }
        return (out, warnings)
    }

    /// Numbers arrive as NSNumber (JSONSerialization), Int or Double (JSONValue), or a string from a careless model.
    static func num(_ v: Any?) -> Double? {
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    static func text(_ v: Any?, max: Int) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    /// The loose JSON form the AI writes, for prompts and MCP output.
    public var jsonObject: [String: Any] {
        func p(_ p: DPoint) -> [Double] { [p.x, p.y] }
        var d: [String: Any] = ["kind": kind.rawValue]
        if let title { d["title"] = title }
        switch kind {
        case .graph:
            if let xLabel { d["x_label"] = xLabel }
            if let yLabel { d["y_label"] = yLabel }
            if xMax != 10 { d["x_max"] = xMax }
            if yMax != 10 { d["y_max"] = yMax }
            if !curves.isEmpty {
                d["curves"] = curves.map { c -> [String: Any] in
                    var o: [String: Any] = ["points": c.points.map(p)]
                    if let l = c.label { o["label"] = l }
                    if c.dashed { o["dashed"] = true }
                    if c.smooth { o["smooth"] = true }
                    return o
                }
            }
            if !markers.isEmpty {
                d["points"] = markers.map { m -> [String: Any] in
                    var o: [String: Any] = ["x": m.at.x, "y": m.at.y]
                    if let l = m.label { o["label"] = l }
                    if let t = m.xTick { o["x_tick"] = t }
                    if let t = m.yTick { o["y_tick"] = t }
                    return o
                }
            }
            if !areas.isEmpty { d["areas"] = areas.map { a -> [String: Any] in var o: [String: Any] = ["points": a.points.map(p)]; if let l = a.label { o["label"] = l }; return o } }
            if !arrows.isEmpty { d["arrows"] = arrows.map { a -> [String: Any] in var o: [String: Any] = ["from": p(a.from), "to": p(a.to)]; if let l = a.label { o["label"] = l }; return o } }
        case .flow:
            d["steps"] = steps
            if cycle { d["cycle"] = true }
        }
        return d
    }

    /// Plain-text description for screen readers and for AI context (no coordinates).
    public var summary: String {
        var parts: [String] = []
        switch kind {
        case .graph:
            if let y = yLabel, let x = xLabel { parts.append("\(y) against \(x)") }
            let names = curves.compactMap(\.label)
            if !names.isEmpty { parts.append("curves " + names.joined(separator: ", ")) }
            let pts = markers.compactMap(\.label)
            if !pts.isEmpty { parts.append("points " + pts.joined(separator: ", ")) }
            let shaded = areas.compactMap(\.label)
            if !shaded.isEmpty { parts.append("shaded " + shaded.joined(separator: ", ")) }
            let moves = arrows.compactMap(\.label)
            if !moves.isEmpty { parts.append("shifts " + moves.joined(separator: ", ")) }
        case .flow:
            parts.append(steps.joined(separator: " → ") + (cycle ? " → back to \(steps.first ?? "start")" : ""))
        }
        return ([title].compactMap { $0 } + parts).joined(separator: ": ")
    }
}

/// A point in diagram or drawing space. Not CGPoint, so the layout stays portable and testable everywhere.
public struct DPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y)
    }

    static func + (a: DPoint, b: DPoint) -> DPoint { DPoint(a.x + b.x, a.y + b.y) }
    static func - (a: DPoint, b: DPoint) -> DPoint { DPoint(a.x - b.x, a.y - b.y) }
    static func * (a: DPoint, k: Double) -> DPoint { DPoint(a.x * k, a.y * k) }
}

// MARK: - Layout

/// What to draw, in drawing coordinates (origin top-left, y down). Renderers only map these to their own calls.
public enum DiagramShape: Equatable, Sendable {
    public enum Stroke: Equatable, Sendable {
        case axis
        case guide
        /// Series index, for the palette.
        case curve(Int, dashed: Bool)
        case arrow
        case box
    }
    public enum Anchor: Equatable, Sendable { case start, middle, end }
    public enum TextRole: Equatable, Sendable { case title, axis, label, tick, step }

    /// A polyline from `start`; when `curves` is set, draw those Bézier segments instead of straight lines.
    case line(start: DPoint, points: [DPoint], curves: [BezierSegment]?, stroke: Stroke)
    case fill(points: [DPoint], tone: Int)
    case dot(DPoint, series: Int)
    case arrowHead(tip: DPoint, from: DPoint)
    case box(origin: DPoint, width: Double, height: Double)
    case text(String, at: DPoint, anchor: Anchor, role: TextRole, series: Int?)
}

/// One cubic Bézier segment: two control points and where it ends.
public struct BezierSegment: Equatable, Sendable {
    public var c1: DPoint, c2: DPoint, end: DPoint
    public init(_ c1: DPoint, _ c2: DPoint, _ end: DPoint) { self.c1 = c1; self.c2 = c2; self.end = end }
}

public enum DiagramLayout {
    public static let fontSize: Double = 12

    /// Shapes for a diagram drawn into `width` × `height`.
    public static func shapes(_ d: Diagram, width: Double, height: Double) -> [DiagramShape] {
        d.kind == .graph ? graph(d, width: width, height: height) : flow(d, width: width, height: height)
    }

    /// A sensible height for a width: graphs are a little wider than tall; flows grow by rows.
    public static func height(_ d: Diagram, width: Double) -> Double {
        let titled = d.title == nil ? 0.0 : 22.0
        switch d.kind {
        case .graph: return (min(width, 520) * 0.72).rounded() + titled
        case .flow:
            let cols = flowColumns(d.steps.count, width: width)
            let rows = Int((Double(d.steps.count) / Double(cols)).rounded(.up))
            // Rows of boxes, the gaps between them, and room under the last row for a cycle's way back.
            return Double(rows) * 86 - 28 + (d.cycle ? 22 : 0) + (d.title == nil ? 4 : 26) + 6
        }
    }

    static func graph(_ d: Diagram, width: Double, height: Double) -> [DiagramShape] {
        var out: [DiagramShape] = []
        let top = (d.title == nil ? 0.0 : 22.0) + (d.yLabel == nil ? 10 : 24)
        let left = 34.0, right = 54.0, bottom = 34.0
        let plotW = max(40, width - left - right), plotH = max(40, height - top - bottom)
        func map(_ p: DPoint) -> DPoint { DPoint(left + p.x / d.xMax * plotW, top + plotH - p.y / d.yMax * plotH) }
        let origin = DPoint(left, top + plotH)
        if let t = d.title { out.append(.text(t, at: DPoint(width / 2, 15), anchor: .middle, role: .title, series: nil)) }

        // Shaded areas first, so lines sit on top.
        for (i, a) in d.areas.enumerated() {
            let pts = a.points.map(map)
            out.append(.fill(points: pts, tone: i))
            if let l = a.label { out.append(.text(l, at: centroid(pts) + DPoint(0, 4), anchor: .middle, role: .label, series: nil)) }
        }
        // Axes.
        out.append(.line(start: DPoint(left, top - 6), points: [origin, DPoint(left + plotW + 10, origin.y)], curves: nil, stroke: .axis))
        if let y = d.yLabel { out.append(.text(y, at: DPoint(left - 4, top - 12), anchor: .start, role: .axis, series: nil)) }
        if let x = d.xLabel { out.append(.text(x, at: DPoint(left + plotW + 10, origin.y + 26), anchor: .end, role: .axis, series: nil)) }
        // Guides and ticks for labelled points.
        for m in d.markers {
            let p = map(m.at)
            if m.xTick != nil || m.yTick != nil {
                out.append(.line(start: DPoint(p.x, origin.y), points: [p, DPoint(left, p.y)], curves: nil, stroke: .guide))
            }
            if let t = m.xTick { out.append(.text(t, at: DPoint(p.x, origin.y + 15), anchor: .middle, role: .tick, series: nil)) }
            if let t = m.yTick { out.append(.text(t, at: DPoint(left - 5, p.y + 4), anchor: .end, role: .tick, series: nil)) }
        }
        // Curves, labelled at their right-hand end.
        for (i, c) in d.curves.enumerated() {
            let pts = c.points.map(map)
            out.append(.line(start: pts[0], points: Array(pts.dropFirst()), curves: c.smooth ? bezier(pts) : nil, stroke: .curve(i, dashed: c.dashed)))
            if let l = c.label {
                let end = pts.max { $0.x < $1.x } ?? pts[pts.count - 1]
                out.append(.text(l, at: DPoint(min(end.x + 5, width - 2), end.y + 4), anchor: .start, role: .label, series: i))
            }
        }
        for a in d.arrows {
            let f = map(a.from), t = map(a.to)
            out.append(.line(start: f, points: [t], curves: nil, stroke: .arrow))
            out.append(.arrowHead(tip: t, from: f))
            if let l = a.label {
                // Beside the arrow's middle, on its left-hand side, so the text never sits on the shaft.
                let mid = (f + t) * 0.5, dx = t.x - f.x, dy = t.y - f.y, len = max(1, (dx * dx + dy * dy).squareRoot())
                let side = DPoint(dy / len * 12, -dx / len * 12)
                out.append(.text(l, at: mid + side + DPoint(0, 4), anchor: side.x < -2 ? .end : side.x > 2 ? .start : .middle, role: .label, series: nil))
            }
        }
        for (i, m) in d.markers.enumerated() {
            let p = map(m.at)
            out.append(.dot(p, series: i))
            if let l = m.label { out.append(.text(l, at: p + DPoint(7, -7), anchor: .start, role: .label, series: nil)) }
        }
        return out
    }

    static func flowColumns(_ n: Int, width: Double) -> Int { max(1, min(n, width < 420 ? 2 : 4)) }

    static func flow(_ d: Diagram, width: Double, height: Double) -> [DiagramShape] {
        var out: [DiagramShape] = []
        let top = d.title == nil ? 4.0 : 26.0
        if let t = d.title { out.append(.text(t, at: DPoint(width / 2, 15), anchor: .middle, role: .title, series: nil)) }
        let cols = flowColumns(d.steps.count, width: width)
        let gap = 34.0, boxH = 58.0, rowH = 86.0
        // A cycle over several rows goes back round the left side, so it needs a gutter there.
        let rounds = d.cycle && d.steps.count > cols
        let left = rounds ? 18.0 : 4.0
        let boxW = (width - left - 4 - gap * Double(cols - 1)) / Double(cols)
        var frames: [(DPoint, Double, Double)] = []
        for (i, step) in d.steps.enumerated() {
            let row = i / cols, col = i % cols
            let o = DPoint(left + Double(col) * (boxW + gap), top + Double(row) * rowH)
            frames.append((o, boxW, boxH))
            out.append(.box(origin: o, width: boxW, height: boxH))
            let lines = wrap(step, width: boxW - 12, lines: 3)
            let firstY = o.y + boxH / 2 + 4 - Double(lines.count - 1) * 7
            for (k, line) in lines.enumerated() {
                out.append(.text(line, at: DPoint(o.x + boxW / 2, firstY + Double(k) * 14), anchor: .middle, role: .step, series: nil))
            }
        }
        func arrow(_ points: [DPoint]) {
            out.append(.line(start: points[0], points: Array(points.dropFirst()), curves: nil, stroke: .arrow))
            out.append(.arrowHead(tip: points[points.count - 1], from: points[points.count - 2]))
        }
        for i in 0..<(frames.count - 1) {
            let (a, w, h) = frames[i], (b, _, _) = frames[i + 1]
            if b.y == a.y {
                arrow([DPoint(a.x + w + 3, a.y + h / 2), DPoint(b.x - 3, b.y + h / 2)])
            } else {
                // Next row: down from this box's bottom, across, and into the next box's top.
                let midY = a.y + h + (rowH - h) / 2
                arrow([DPoint(a.x + w / 2, a.y + h + 3), DPoint(a.x + w / 2, midY), DPoint(b.x + w / 2, midY), DPoint(b.x + w / 2, b.y - 3)])
            }
        }
        if d.cycle, frames.count >= 2, let (last, w, h) = frames.last {
            let (first, _, _) = frames[0]
            let below = (frames.map { $0.0.y }.max() ?? 0) + h + 16
            if rounds {
                // Down from the last box, along the bottom, up the left gutter and into the first box's side, never
                // through another box.
                let gutter = left / 2
                arrow([DPoint(last.x + w / 2, last.y + h + 3), DPoint(last.x + w / 2, below), DPoint(gutter, below),
                       DPoint(gutter, first.y + h / 2), DPoint(first.x - 3, first.y + h / 2)])
            } else {
                arrow([DPoint(last.x + w / 2, last.y + h + 3), DPoint(last.x + w / 2, below), DPoint(first.x + w / 2, below), DPoint(first.x + w / 2, first.y + h + 3)])
            }
        }
        return out
    }

    /// Catmull-Rom through the points, as cubic Bézier segments (control 1, control 2, end).
    public static func bezier(_ p: [DPoint]) -> [BezierSegment] {
        guard p.count >= 3 else { return p.count == 2 ? [BezierSegment(p[0], p[1], p[1])] : [] }
        var out: [BezierSegment] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            out.append(BezierSegment(p1 + (p2 - p0) * (1.0 / 6), p2 - (p3 - p1) * (1.0 / 6), p2))
        }
        return out
    }

    static func centroid(_ p: [DPoint]) -> DPoint {
        guard !p.isEmpty else { return DPoint(0, 0) }
        return DPoint(p.map(\.x).reduce(0, +) / Double(p.count), p.map(\.y).reduce(0, +) / Double(p.count))
    }

    /// Word-wraps by an average glyph width; the last line is shortened with an ellipsis if the text doesn't fit.
    public static func wrap(_ s: String, width: Double, lines maxLines: Int, fontSize: Double = DiagramLayout.fontSize) -> [String] {
        let perLine = max(4, Int(width / (fontSize * 0.56)))
        var lines: [String] = []
        var current = ""
        for word in s.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= perLine { current = candidate; continue }
            if !current.isEmpty { lines.append(current) }
            current = word.count > perLine ? String(word.prefix(perLine - 1)) + "…" : word
        }
        if !current.isEmpty { lines.append(current) }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            let last = lines[maxLines - 1]
            lines[maxLines - 1] = (last.count >= perLine ? String(last.prefix(perLine - 1)) : last) + "…"
        }
        return lines
    }
}

// MARK: - SVG

/// Standalone SVG for exports (Markdown, Obsidian). The app draws the same layout natively.
public enum DiagramSVG {
    /// Readable on white and in most Markdown viewers' dark themes; the series colors pass 3:1 against both.
    public static let series = ["#2f6fd6", "#d6602f", "#1f9a6b", "#8b5cd6", "#c2416b", "#6b7280"]
    /// Shaded areas use their own hues so a fill never looks like it belongs to a curve.
    public static let areaFills = ["#e0a526", "#8b5cd6", "#c2416b", "#6b7280"]
    public static let ink = "#3a3f47"

    public static func render(_ d: Diagram, width: Double = 480) -> String {
        let height = DiagramLayout.height(d, width: width)
        var body: [String] = []
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        func color(_ i: Int) -> String { series[i % series.count] }
        for s in DiagramLayout.shapes(d, width: width, height: height) {
            switch s {
            case let .line(start, points, curves, stroke):
                var path = "M\(f(start.x)) \(f(start.y))"
                if let curves {
                    for c in curves { path += " C\(f(c.c1.x)) \(f(c.c1.y)) \(f(c.c2.x)) \(f(c.c2.y)) \(f(c.end.x)) \(f(c.end.y))" }
                } else {
                    for p in points { path += " L\(f(p.x)) \(f(p.y))" }
                }
                let (stroke, w, dash): (String, Double, String?) = {
                    switch stroke {
                    case .axis: return (ink, 1.5, nil)
                    case .guide: return (ink, 1, "3 3")
                    case .curve(let i, let dashed): return (color(i), 2.25, dashed ? "6 4" : nil)
                    case .arrow: return (ink, 1.5, nil)
                    case .box: return (ink, 1, nil)
                    }
                }()
                body.append("<path d=\"\(path)\" fill=\"none\" stroke=\"\(stroke)\" stroke-width=\"\(f(w))\"\(dash.map { " stroke-dasharray=\"\($0)\"" } ?? "") stroke-linecap=\"round\" stroke-linejoin=\"round\"/>")
            case let .fill(points, tone):
                body.append("<polygon points=\"\(points.map { "\(f($0.x)),\(f($0.y))" }.joined(separator: " "))\" fill=\"\(areaFills[tone % areaFills.count])\" fill-opacity=\"0.22\"/>")
            case let .dot(p, _):
                body.append("<circle cx=\"\(f(p.x))\" cy=\"\(f(p.y))\" r=\"3.5\" fill=\"\(ink)\"/>")
            case let .arrowHead(tip, from):
                let (a, b) = arrowWings(tip: tip, from: from)
                body.append("<path d=\"M\(f(a.x)) \(f(a.y)) L\(f(tip.x)) \(f(tip.y)) L\(f(b.x)) \(f(b.y))\" fill=\"none\" stroke=\"\(ink)\" stroke-width=\"1.5\" stroke-linecap=\"round\"/>")
            case let .box(o, w, h):
                body.append("<rect x=\"\(f(o.x))\" y=\"\(f(o.y))\" width=\"\(f(w))\" height=\"\(f(h))\" rx=\"7\" fill=\"#ffffff\" fill-opacity=\"0.6\" stroke=\"\(ink)\" stroke-width=\"1\"/>")
            case let .text(t, at, anchor, role, seriesIndex):
                let a = anchor == .start ? "start" : anchor == .middle ? "middle" : "end"
                let size = role == .title ? 13 : role == .tick ? 11 : 12
                let weight = role == .title || role == .label ? " font-weight=\"600\"" : ""
                let fill = seriesIndex.map(color) ?? ink
                // A white halo keeps labels readable where they cross a line.
                let halo = role == .step || role == .title ? "" : " stroke=\"#ffffff\" stroke-width=\"3\" stroke-linejoin=\"round\" paint-order=\"stroke\""
                body.append("<text x=\"\(f(at.x))\" y=\"\(f(at.y))\" text-anchor=\"\(a)\" font-size=\"\(size)\"\(weight) fill=\"\(fill)\"\(halo)>\(escape(t))</text>")
            }
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(f(width)) \(f(height))" width="\(f(width))" height="\(f(height))" font-family="-apple-system, Helvetica, Arial, sans-serif" role="img" aria-label="\(escape(d.summary))">
        \(body.joined(separator: "\n"))
        </svg>
        """
    }

    /// The two ends of an arrowhead's wings, 9 points back from the tip at ±28°.
    public static func arrowWings(tip: DPoint, from: DPoint, length: Double = 9) -> (DPoint, DPoint) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let spread = 0.49
        return (DPoint(tip.x - length * cos(angle - spread), tip.y - length * sin(angle - spread)),
                DPoint(tip.x - length * cos(angle + spread), tip.y - length * sin(angle + spread)))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Diagrams inside chat replies

/// Splits an AI reply into text and ```diagram blocks, so a chat can draw a graph inline.
public enum DiagramBlocks {
    public enum Segment: Equatable {
        case text(String)
        case diagram(Diagram)
        /// A diagram block still streaming in (no closing fence yet).
        case pending
    }

    public static func split(_ text: String) -> [Segment] {
        guard text.contains("```diagram") else { return [.text(text)] }
        var out: [Segment] = []
        var rest = Substring(text)
        while let open = rest.range(of: "```diagram") {
            let before = String(rest[..<open.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(before.trimmingCharacters(in: .newlines))) }
            let body = rest[open.upperBound...]
            guard let close = body.range(of: "```") else { out.append(.pending); return out }
            let json = String(body[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Diagram.parse(JSON.parse(json)).diagram { out.append(.diagram(d)) } else { out.append(.text("```\n\(json)\n```")) }
            rest = body[close.upperBound...]
        }
        let tail = String(rest).trimmingCharacters(in: .newlines)
        if !tail.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.text(tail)) }
        return out
    }
}
