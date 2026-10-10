import Foundation

/// Fixes the two ways models most often garble what they write for the student. Left unescaped in JSON, LaTeX loses
/// its backslashes: "\times" arrives as a tab and "imes", "\frac" as a form feed and "rac". And small models answer
/// "Markdown" with HTML lists.
public enum TextRepair {
    static let escapes: [Character: String] = ["\t": "\\t", "\u{0C}": "\\f", "\u{08}": "\\b", "\r": "\\r", "\n": "\\n"]

    /// A formula: no control character belongs in LaTeX, so each one is the backslash command it came from.
    public static func latex(_ s: String) -> String {
        String(s.flatMap { escapes[$0].map(Array.init) ?? [$0] })
    }

    /// Markdown: the same repair inside $…$ maths (where a newline only comes back as "\n" when a command's letters
    /// follow), form feeds and backspaces everywhere, and simple HTML turned into Markdown.
    public static func markdown(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\u{0C}", with: "\\f").replacingOccurrences(of: "\u{08}", with: "\\b")
        if out.contains("$") {
            var result = ""
            var inMath = false
            let chars = Array(out)
            for (i, c) in chars.enumerated() {
                if c == "$" { inMath.toggle(); result.append(c); continue }
                guard inMath else { result.append(c); continue }
                switch c {
                case "\t": result += "\\t"
                case "\r": result += "\\r"
                case "\n" where i + 1 < chars.count && chars[i + 1].isLetter && chars[i + 1].isLowercase: result += "\\n"
                default: result.append(c)
                }
            }
            out = result
        }
        guard out.range(of: #"</?(ul|ol|li|p|br|strong|b|em|i|h[1-6])\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) != nil else { return out }
        for (pattern, replacement) in [(#"<li\b[^>]*>"#, "\n- "), (#"</li>"#, ""), (#"</?(ul|ol)\b[^>]*>"#, "\n"), (#"<br\s*/?>"#, "\n"),
                                       (#"<p\b[^>]*>"#, ""), (#"</p>"#, "\n\n"), (#"</?(strong|b)>"#, "**"), (#"</?(em|i)>"#, "*"),
                                       (#"<h[1-6]\b[^>]*>"#, "\n**"), (#"</h[1-6]>"#, "**\n")] {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
