import Foundation
import CoreGraphics
import CoreText

public struct CornellSheet: Equatable {
    public struct Cue: Equatable { public var text: String; public var kind: String; public var sourceLocators: [String] }
    public var title: String
    public var courseCode: String
    public var materialTitle: String
    public var date: String
    public var cues: [Cue]
    public var summaryPrompt: String
    public var lookYourself: [String]

    public init(title: String, courseCode: String, materialTitle: String, date: String, cues: [Cue], summaryPrompt: String, lookYourself: [String]) {
        self.title = title; self.courseCode = courseCode; self.materialTitle = materialTitle; self.date = date
        self.cues = cues; self.summaryPrompt = summaryPrompt; self.lookYourself = lookYourself
    }

    public var json: String {
        JSON.string([
            "title": title, "courseCode": courseCode, "materialTitle": materialTitle, "date": date,
            "cues": cues.map { ["text": $0.text, "kind": $0.kind, "sourceLocators": $0.sourceLocators] },
            "summaryPrompt": summaryPrompt, "lookYourself": lookYourself,
        ])
    }

    public static func decode(_ s: String?) -> CornellSheet? {
        guard let d = JSON.parse(s) as? [String: Any] else { return nil }
        let cues = (d["cues"] as? [[String: Any]] ?? []).map {
            Cue(text: $0["text"] as? String ?? "", kind: $0["kind"] as? String ?? "question", sourceLocators: $0["sourceLocators"] as? [String] ?? [])
        }
        return CornellSheet(title: d["title"] as? String ?? "", courseCode: d["courseCode"] as? String ?? "",
                            materialTitle: d["materialTitle"] as? String ?? "", date: d["date"] as? String ?? "", cues: cues,
                            summaryPrompt: d["summaryPrompt"] as? String ?? "", lookYourself: d["lookYourself"] as? [String] ?? [])
    }

    public var markdown: String {
        var md = "# \(title)\n\n\(courseCode) · \(materialTitle) · \(date)\n\n## Cues\n\n"
        for (i, c) in cues.enumerated() {
            md += "\(i + 1). \(c.text)" + (c.sourceLocators.isEmpty ? "" : " _(\(c.sourceLocators.joined(separator: ", ")))_") + "\n"
        }
        md += "\n## Summary\n\n\(summaryPrompt)\n"
        if !lookYourself.isEmpty { md += "\n## Look at these yourself\n\n" + lookYourself.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return md
    }

    /// Obsidian-friendly Markdown with YAML frontmatter (§9.3).
    public var obsidianMarkdown: String {
        "---\ncourse: \"\(courseCode)\"\nmaterial: \"\(materialTitle.replacingOccurrences(of: "\"", with: "'"))\"\ntype: cornell_sheet\ndate: \(date)\n---\n\n" + markdown
    }
}
