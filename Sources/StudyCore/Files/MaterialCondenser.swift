import Foundation

/// Strips what costs tokens without teaching anything, on this Mac, before a lecture goes to an AI: footers and
/// headers repeated on every slide, slide numbers, "Thank you" and "Questions?" slides, repeated agenda slides, and
/// overlong speaker notes. Chunk ids stay the same, so citations still point at the original slides.
public enum MaterialCondenser {
    public struct Result {
        public var chunks: [Chunk]
        public var dropped: Int
        public var tokensBefore: Int
        public var tokensAfter: Int
    }

    static let fillerPattern = #"^(thank(s| you)( for (listening|your attention))?|questions\??|any questions\??|q ?& ?a|discussion|break|the end|end|fin|merci)[.!?]*$"#
    static let noisePattern = #"^((slide|page|p\.)\s*\d+(\s*(of|/)\s*\d+)?|\d{1,3}(\s*(of|/)\s*\d{1,3})?|©.*|copyright.*|all rights reserved.*)$"#

    public static func condense(_ chunks: [Chunk], maxNotes: Int = 800, maxExtra: Int = 1_500) -> Result {
        let before = chunks.reduce(0) { $0 + $1.tokenEstimate }
        // Lines repeated on many slides are headers and footers.
        var seenIn: [String: Int] = [:]
        for c in chunks {
            for key in Set(lines(c.textMd).map(normalize)) where !key.isEmpty { seenIn[key, default: 0] += 1 }
        }
        let threshold = max(3, Int((Double(chunks.count) * 0.4).rounded(.up)))
        let boilerplate: Set<String> = chunks.count >= 4 ? Set(seenIn.filter { $0.value >= threshold && $0.key.count <= 120 }.keys) : []

        var out: [Chunk] = []
        var seenBodies = Set<String>()
        for c in chunks {
            var kept: [String] = []
            for line in lines(c.textMd) {
                let key = normalize(line)
                if key.isEmpty || boilerplate.contains(key) || key.range(of: noisePattern, options: .regularExpression) != nil { continue }
                if kept.last.map(normalize) == key { continue }
                kept.append(line)
            }
            // A heading repeated as the first line.
            if let h = c.heading, let first = kept.first, normalize(first) == normalize(h) { kept.removeFirst() }
            let text = kept.joined(separator: "\n")
            let notes = c.notesMd.map { clip($0.trimmingCharacters(in: .whitespacesAndNewlines), maxNotes) }.flatMap { $0.isEmpty ? nil : $0 }
            let extra = c.extraMd.map { clip($0.trimmingCharacters(in: .whitespacesAndNewlines), maxExtra) }.flatMap { $0.isEmpty ? nil : $0 }
            let body = normalize([c.heading ?? "", text].joined(separator: " "))
            let words = body.split(separator: " ").count
            if text.isEmpty && notes == nil && extra == nil { continue }
            if notes == nil && extra == nil && words <= 6 && body.range(of: fillerPattern, options: .regularExpression) != nil { continue }
            if notes == nil && !body.isEmpty && !seenBodies.insert(body).inserted { continue }
            // Scale the parser's estimate by how much text is left, so sectioning stays consistent with it.
            let oldChars = max(1, c.textMd.count + (c.notesMd?.count ?? 0) + (c.extraMd?.count ?? 0))
            let newChars = text.count + (notes?.count ?? 0) + (extra?.count ?? 0)
            let estimate = newChars >= oldChars ? c.tokenEstimate : max(1, Int((Double(c.tokenEstimate) * Double(newChars) / Double(oldChars)).rounded(.up)))
            out.append(Chunk(id: c.id, materialId: c.materialId, ordinal: c.ordinal, locator: c.locator, heading: c.heading, textMd: text,
                             notesMd: notes, extraMd: extra, imageCount: c.imageCount, images: c.images, ocr: c.ocr, tokenEstimate: estimate))
        }
        // Never hand an AI nothing: if everything looked like noise, keep the original.
        if out.isEmpty { return Result(chunks: chunks, dropped: 0, tokensBefore: before, tokensAfter: before) }
        return Result(chunks: out, dropped: chunks.count - out.count, tokensBefore: before, tokensAfter: out.reduce(0) { $0 + $1.tokenEstimate })
    }

    /// Non-empty lines, indentation kept (it carries the bullet hierarchy).
    static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { line in
            var l = String(line)
            while let last = l.last, last.isWhitespace { l.removeLast() }
            return l
        }.filter { l in l.contains { $0.isLetter || $0.isNumber } }
    }

    /// Lower-cased, bullets and punctuation runs trimmed, spaces collapsed.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"^[\s\-*•·▪◦–—>#\d.)]*\s"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
}
