import XCTest
@testable import StudyCore

/// Manual tool: `RENDER_SHEET_DB=/path/study.db RENDER_SHEET_OUT=/path/out.pdf swift test --filter RenderSheetTool`
final class RenderSheetTool: XCTestCase {
    func testRenderSheetFromDatabase() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dbPath = env["RENDER_SHEET_DB"], let out = env["RENDER_SHEET_OUT"] else { throw XCTSkip("manual tool") }
        let db = try Database(path: dbPath, readOnly: true)
        let row = try XCTUnwrap(try db.first("SELECT data_json FROM notes WHERE kind = 'cornell_sheet' ORDER BY id DESC LIMIT 1"))
        let sheet = try XCTUnwrap(CornellSheet.decode(row.string("data_json")))
        try CornellRenderer.pdf(sheet, paper: .a4).write(to: URL(fileURLWithPath: out))
    }
}
