import Foundation

/// Short LaTeX inside a sentence ("where $P^*$ is the equilibrium price") as runs a native text view can show: Greek
/// letters and operators become Unicode, fractions become a/b, and sub- and superscripts are marked for the view to
/// lower or raise. Whole formulas on a notebook page are typeset properly; this is for the maths inside definitions.
public enum InlineMath {
    public enum Level: Equatable, Sendable { case base, sup, sub }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var level: Level
        /// From a formula (shown in italics), not the surrounding words.
        public var math: Bool
        public init(_ text: String, _ level: Level = .base, math: Bool = true) { self.text = text; self.level = level; self.math = math }
    }

    /// Splits text on `$…$` (and `$$…$$`) and turns each formula into runs. Text without a closing `$` stays as it is.
    public static func runs(_ text: String) -> [Run] {
        var out: [Run] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "$") {
            let afterOpen = rest.index(after: open)
            let double = afterOpen < rest.endIndex && rest[afterOpen] == "$"
            let start = double ? rest.index(after: afterOpen) : afterOpen
            guard let close = rest[start...].range(of: double ? "$$" : "$") else { break }
            if open > rest.startIndex { out.append(Run(String(rest[..<open]), math: false)) }
            out += formula(String(rest[start..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { out.append(Run(String(rest), math: false)) }
        return merged(out)
    }

    /// One formula as runs.
    public static func formula(_ latex: String) -> [Run] {
        var p = Parser(Array(latex))
        return merged(p.parse(level: .base, until: nil))
    }

    /// A formula as one plain line, with Unicode sub- and superscripts where they exist: for exports and VoiceOver.
    public static func plain(_ latex: String) -> String {
        formula(latex).map { r in
            switch r.level {
            case .base: return r.text
            case .sup: return script(r.text, superscripts) ?? (r.text == "*" || r.text == "′" ? r.text : "^" + wrap(r.text))
            case .sub: return script(r.text, subscripts) ?? "_" + wrap(r.text)
            }
        }.joined()
    }

    static func wrap(_ s: String) -> String { s.count == 1 ? s : "(\(s))" }

    static func script(_ s: String, _ table: [Character: Character]) -> String? {
        var out = ""
        for c in s { guard let m = table[c] else { return nil }; out.append(m) }
        return out
    }

    static func merged(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for r in runs where !r.text.isEmpty {
            if let last = out.last, last.level == r.level, last.math == r.math { out[out.count - 1].text += r.text } else { out.append(r) }
        }
        return out
    }

    // MARK: Parsing

    struct Parser {
        let s: [Character]
        var i = 0
        init(_ s: [Character]) { self.s = s }

        mutating func parse(level: Level, until end: Character?) -> [Run] {
            var out: [Run] = []
            while i < s.count {
                let c = s[i]
                if let end, c == end { i += 1; return out }
                switch c {
                case "\\": out += command(level: level)
                case "^", "_":
                    i += 1
                    let inner: Level = c == "^" ? .sup : .sub
                    // A script of a script stays at the first level; there's only one raised line in plain text.
                    out += argument(level: level == .base ? inner : level)
                case "{": i += 1; out += parse(level: level, until: "}")
                case "}": i += 1
                case "~": i += 1; out.append(Run(" ", level))
                case "'": i += 1; out.append(Run("′", level))
                case " ", "\n", "\t": i += 1; if level == .base, out.last?.text.last != " " { out.append(Run(" ", level)) }
                default: i += 1; out.append(Run(String(c), level))
                }
            }
            return out
        }

        /// The next `{group}` or single character (or command).
        mutating func argument(level: Level) -> [Run] {
            while i < s.count, s[i] == " " { i += 1 }
            guard i < s.count else { return [] }
            if s[i] == "{" { i += 1; return parse(level: level, until: "}") }
            if s[i] == "\\" { return command(level: level) }
            defer { i += 1 }
            return [Run(String(s[i]), level)]
        }

        /// A `{group}` read as literal text (for \text and friends).
        mutating func literal() -> String {
            while i < s.count, s[i] == " " { i += 1 }
            guard i < s.count, s[i] == "{" else { return "" }
            i += 1
            var depth = 1, out = ""
            while i < s.count {
                let c = s[i]; i += 1
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { break } }
                out.append(c)
            }
            return out
        }

        mutating func command(level: Level) -> [Run] {
            i += 1   // the backslash
            guard i < s.count else { return [] }
            if !s[i].isLetter {
                let c = s[i]; i += 1
                switch c {
                case ",", ":", ";", " ": return [Run(" ", level)]
                case "!": return []
                default: return [Run(String(c), level)]   // \{ \} \% \$ \& \_ \#
                }
            }
            var name = ""
            while i < s.count, s[i].isLetter { name.append(s[i]); i += 1 }
            // A space after a letter command only ends its name ("\Delta Q" is ΔQ); operators keep theirs.
            if let sym = InlineMath.symbols[name], sym.count == 1, sym.first!.isLetter {
                while i < s.count, s[i] == " " { i += 1 }
            }
            switch name {
            case "frac", "dfrac", "tfrac":
                let a = argument(level: level), b = argument(level: level)
                return grouped(a, level) + [Run("/", level)] + grouped(b, level)
            case "sqrt":
                return [Run("√", level)] + grouped(argument(level: level), level)
            case "text", "textrm", "textit", "textbf", "mathrm", "mathit", "mathbf", "mathsf", "mathcal", "operatorname", "boldsymbol", "mbox":
                return [Run(literal(), level, math: false)]
            case "mathbb":
                return [Run(String(literal().map { InlineMath.blackboard[$0] ?? $0 }), level)]
            case "bar", "overline", "hat", "widehat", "tilde", "widetilde", "vec", "dot", "ddot":
                let inner = argument(level: level)
                let text = inner.map(\.text).joined()
                guard text.count == 1, let mark = InlineMath.accents[name] else { return inner }
                return [Run(text + String(mark), level)]
            case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "textstyle", "limits", "nolimits":
                return []
            case "quad": return [Run("  ", level)]
            case "qquad": return [Run("    ", level)]
            default:
                if let sym = InlineMath.symbols[name] { return [Run(sym, level)] }
                return [Run(name, level)]
            }
        }

        /// Brackets a fraction's part when it's more than one item, so a/b stays unambiguous: (a + b)/2.
        func grouped(_ runs: [Run], _ level: Level) -> [Run] {
            let text = runs.map(\.text).joined()
            let simple = text.count <= 1 || text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } || runs.contains { $0.level != level }
            return simple && !text.contains(" ") ? runs : [Run("(", level)] + runs + [Run(")", level)]
        }
    }

    static let blackboard: [Character: Character] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "E": "𝔼"]

    static let accents: [String: Character] = [
        "bar": "\u{0304}", "overline": "\u{0304}", "hat": "\u{0302}", "widehat": "\u{0302}", "tilde": "\u{0303}",
        "widetilde": "\u{0303}", "vec": "\u{20D7}", "dot": "\u{0307}", "ddot": "\u{0308}",
    ]

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ",
        "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼", "equiv": "≡", "propto": "∝", "infty": "∞", "partial": "∂",
        "nabla": "∇", "sum": "Σ", "prod": "Π", "int": "∫", "to": "→", "rightarrow": "→", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔", "Leftrightarrow": "⇔", "uparrow": "↑", "downarrow": "↓",
        "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃",
        "emptyset": "∅", "prime": "′", "circ": "∘", "degree": "°", "ldots": "…", "cdots": "⋯", "dots": "…",
        "log": "log", "ln": "ln", "exp": "exp", "sin": "sin", "cos": "cos", "tan": "tan", "max": "max", "min": "min",
        "lim": "lim", "Pr": "Pr", "%": "%",
    ]

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "t": "ᵗ", "T": "ᵀ",
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "n": "ₙ", "o": "ₒ", "t": "ₜ", "x": "ₓ",
    ]
}
