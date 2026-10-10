import Foundation

/// One problem from a problem set, class example or past exam, word for word.
public struct PracticeDraft: Equatable, Sendable {
    /// "1", "2a", "Q3".
    public var number: String
    public var prompt: String
    /// The worked solution, when the file (or its solutions file) has one.
    public var solution: String?
    public var chunkIds: [Int]
    /// "p. 2" or "p. 2–3".
    public var locator: String
    public var marks: Double?

    public init(number: String, prompt: String, solution: String? = nil, chunkIds: [Int], locator: String, marks: Double? = nil) {
        self.number = number; self.prompt = prompt; self.solution = solution; self.chunkIds = chunkIds; self.locator = locator; self.marks = marks
    }
}

/// Splits a problem set, a class example or a past exam into its problems without any AI, so the practice bank works
/// on every Mac and the text is always the course's own. Problems are found by their headings ("Exercise 3",
/// "Aufgabe 2", "Q4", "Question 1 (10 marks)"), or by a numbered list when there are no headings. Solutions inside the
/// same file ("Solution:", "Lösung:") are split off, and a separate solutions file is matched by number.
public enum PracticeSplitter {
    /// At most this many problems per file; anything longer is a book, not a problem set.
    public static let maxItems = 40

    struct Piece { var chunkId: Int; var locator: String; var range: Range<Int> }

    /// With `answers`, the file is a solutions file: an item is kept for its answer even when its "prompt" is just the
    /// heading ("Exercise 1\nSolution: x = 5"), since `attachSolutions` reads both.
    public static func split(_ chunks: [Chunk], answers solutionsFile: Bool = false) -> [PracticeDraft] {
        // One text for the whole file, remembering where each chunk sits in it.
        var text = ""
        var pieces: [Piece] = []
        for c in chunks {
            let body = [c.heading.flatMap { h in c.textMd.contains(h) ? nil : h }, c.textMd, c.extraMd?.replacingOccurrences(of: #"Text in pictures:[\s\S]*"#, with: "", options: .regularExpression)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            if !text.isEmpty { text += "\n\n" }
            let start = text.utf16.count
            text += body
            pieces.append(Piece(chunkId: c.id, locator: c.locator, range: start..<text.utf16.count))
        }
        guard !text.isEmpty else { return [] }
        let ns = text as NSString

        var markers = matches(of: headingPattern, in: text)
        if markers.count < 2 { markers = numberedList(in: text) }
        // A "Solutions" part after the problems: its answers go with their problems by number, not into the last one.
        var problemsEnd = ns.length
        var answers: [PracticeDraft] = []
        if let first = markers.first, let section = firstMatch(solutionsSectionPattern, in: text), section.location > first.range.location {
            problemsEnd = section.location
            markers = markers.filter { $0.range.location < section.location }
            answers = numberedAnswers(ns.substring(from: section.location + section.length))
        }
        var items: [PracticeDraft] = []
        if markers.count >= 2 {
            for (i, m) in markers.enumerated() {
                let end = i + 1 < markers.count ? markers[i + 1].range.location : problemsEnd
                let range = NSRange(location: m.range.location, length: end - m.range.location)
                items.append(item(number: m.number, text: ns.substring(with: range), range: range, pieces: pieces))
            }
        } else if pieces.count > 6 {
            // A long file with no numbering (slides of worked examples): one problem per slide or page.
            for (i, p) in pieces.enumerated() {
                let range = NSRange(location: p.range.lowerBound, length: p.range.count)
                items.append(item(number: "\(i + 1)", text: ns.substring(with: range), range: range, pieces: pieces))
            }
        } else {
            // A worksheet or a single task: the whole file is the problem.
            let range = NSRange(location: 0, length: ns.length)
            items.append(item(number: "1", text: text, range: range, pieces: pieces))
        }
        if !answers.isEmpty { items = attachSolutions(items, from: answers) }
        let kept = items.filter { item in
            if item.prompt.count >= 15 { return true }
            return solutionsFile && !stripHeading([item.prompt, item.solution].compactMap { $0 }.joined(separator: "\n\n")).isEmpty
        }
        return Array(kept.prefix(maxItems))
    }

    /// A heading line on its own: "Solutions", "Answers", "Lösungen", "Soluciones"…
    static let solutionsSectionPattern = #"(?im)^[ \t#*>]*(?:solutions?|answers?|answer key|worked solutions|model answers|suggested solutions|lösungen|loesungen|soluciones|respuestas|corrigés?|corriges?|soluzioni|risposte|uitwerkingen|antwoorden|resoluções|resolucoes|respostas)[ \t]*:?[ \t]*$"#

    /// The answers in a solutions part, each under its number: "Solution 1:", "1.", "Q2)", "Exercise 3 –".
    static func numberedAnswers(_ text: String) -> [PracticeDraft] {
        let pattern = #"(?im)^[ \t#*>\-]*(?:(?:solution|answer|exercise|question|problem|lösung|losung|aufgabe|solución|solucion|respuesta|ejercicio|soluzione|esercizio|corrigé|exercice|q)\.?[ \t]*)?(\d{1,2}[a-z]?)[ \t]*[:.)\-–]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let found = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return found.enumerated().map { i, m in
            let end = i + 1 < found.count ? found[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: m.range.location + m.range.length, length: end - m.range.location - m.range.length))
            return PracticeDraft(number: ns.substring(with: m.range(at: 1)), prompt: body.trimmingCharacters(in: .whitespacesAndNewlines), solution: nil,
                                 chunkIds: [], locator: "", marks: nil)
        }
    }

    /// Fills in solutions from a separate solutions file, matching problems by number.
    public static func attachSolutions(_ items: [PracticeDraft], from solutions: [PracticeDraft]) -> [PracticeDraft] {
        let byNumber = Dictionary(solutions.map { (normalizeNumber($0.number), $0) }, uniquingKeysWith: { a, _ in a })
        return items.map { item in
            var item = item
            guard item.solution == nil, let s = byNumber[normalizeNumber(item.number)] else { return item }
            let answer = [s.prompt, s.solution].compactMap { $0 }.joined(separator: "\n\n")
            item.solution = clip(stripHeading(answer), 6_000)
            return item
        }
    }

    // MARK: Items

    static func item(number: String, text: String, range: NSRange, pieces: [Piece]) -> PracticeDraft {
        var prompt = text
        var solution: String?
        let ns = text as NSString
        if let m = firstMatch(solutionPattern, in: text) {
            prompt = ns.substring(to: m.location)
            solution = ns.substring(from: m.location + m.length)
        }
        let covered = pieces.filter { $0.range.overlaps(range.location..<(range.location + max(range.length, 1))) }
        let locator = covered.count > 1 && covered.first?.locator != covered.last?.locator
            ? "\(covered.first!.locator)–\(covered.last!.locator.replacingOccurrences(of: #"^\D+"#, with: "", options: .regularExpression))"
            : covered.first?.locator ?? ""
        return PracticeDraft(number: number, prompt: clip(prompt.trimmingCharacters(in: .whitespacesAndNewlines), 4_000),
                             solution: solution.map { clip($0.trimmingCharacters(in: .whitespacesAndNewlines), 6_000) }.flatMap { $0.isEmpty ? nil : $0 },
                             chunkIds: covered.map(\.chunkId), locator: locator, marks: marks(in: prompt))
    }

    /// "(10 marks)", "[5 points]", "(4 pts)", "(6 Punkte)".
    public static func marks(in text: String) -> Double? {
        let pattern = #"[\(\[]\s*(\d{1,3}(?:[.,]\d)?)\s*(?:marks?|points?|pts?|punkte|points|puntos|punti|punten|pontos)\s*[\)\]]"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r].replacingOccurrences(of: ",", with: "."))
    }

    // MARK: Markers

    struct Marker { var number: String; var range: NSRange }

    /// A problem heading at the start of a line: "Exercise 3", "Problem 2b:", "Q4.", "**Aufgabe 1**", "Ejercicio 5 –".
    /// Only the keyword ignores case: after the number comes punctuation, the end of the line or a capitalised word
    /// ("Aufgabe 1 Berechnen Sie…"), so "question 3 of the reading" in a sentence isn't a heading.
    static let headingPattern = #"(?m)^[ \t#*>\-]*(?i:exercise|problem|question|task|q|aufgabe|übung|ubung|frage|exercice|ejercicio|pregunta|esercizio|domanda|opgave|oefening|vraag|exercício|exercicio|questão|questao)\.?[ \t]*(\d{1,2}[a-z]?)(?=[ \t]*(?:[:.)\-–—*]|\(|\[|$)|[ \t]+[A-ZÀ-ÖØ-Þ])"#

    static func matches(of pattern: String, in text: String) -> [Marker] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [Marker] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let number = ns.substring(with: m.range(at: 1))
            // Repeats of the same number (a heading quoted again in a solution) don't start a new problem.
            if out.contains(where: { normalizeNumber($0.number) == normalizeNumber(number) }) { continue }
            out.append(Marker(number: number, range: m.range))
        }
        return out
    }

    /// "1. … 2. … 3. …" at the start of lines, counting up from 1, when there are no headings.
    static func numberedList(in text: String) -> [Marker] {
        guard let re = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(\d{1,2})[.)][ \t]+\S"#) else { return [] }
        let ns = text as NSString
        var out: [Marker] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            if n == out.count + 1 { out.append(Marker(number: "\(n)", range: m.range)) }
        }
        return out.count >= 2 ? out : []
    }

    /// Where a worked solution starts inside a problem: "Solution:", "Answer:", "Lösung:", "Corrigé :".
    static let solutionPattern = #"(?im)^[ \t#*>\-]*(?:solution|suggested solution|model answer|answer|worked solution|lösung|losung|corrigé|corrige|correction|solución|solucion|respuesta|soluzione|risposta|uitwerking|antwoord|resolução|resolucao|resposta)[ \t]*\d*[ \t]*[:.\-–]"#

    static func firstMatch(_ pattern: String, in text: String) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return m.range
    }

    static func stripHeading(_ s: String) -> String {
        s.replacingOccurrences(of: headingPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s:.)\-–—*]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeNumber(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
}
