import XCTest
@testable import StudyCore
@testable import StudyAI

/// Real engines, opt-in: `STUDY_LIVE_AI=1 swift test --filter LiveAITests`. Skipped otherwise, so the normal suite never
/// depends on a model, a network or Apple Intelligence being enabled.
final class LiveAITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STUDY_LIVE_AI"] == "1", "Set STUDY_LIVE_AI=1 to run live engine tests.")
    }

    func testAppleOnDeviceProcessesALecture() async throws {
        #if canImport(FoundationModels)
        let a = AppleProviders.availability(Catalog.appleOnDevice)
        try XCTSkipUnless(a.available, a.reason ?? "Apple Intelligence unavailable")
        let store = try makeStore(file: true)
        let ids = try seedCourses(store)
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Overbooking", bullets: [(0, "Hotels sell more rooms than they have"), (0, "Because some guests don't show up")], notes: "Expected no-shows offset the extra bookings.", picture: nil, table: nil, chart: false),
            (title: "No-show rate", bullets: [(0, "Share of reservations that don't arrive"), (0, "Forecast from history by day of week")], notes: nil, picture: nil, table: nil, chart: false),
            (title: "Walking a guest", bullets: [(0, "Relocating an overbooked guest to another hotel"), (0, "Pay for the room, transport and an apology")], notes: nil, picture: nil, table: nil, chart: false),
            (title: "RevPAR", bullets: [(0, "Revenue per available room = ADR x occupancy"), (0, "Example: ADR 120, occupancy 80% gives RevPAR 96")], notes: nil, picture: nil, table: nil, chart: false),
        ])
        guard case .imported(let mid, _) = store.importMaterial(from: deck, courseId: ids.hm) else { return XCTFail() }
        let provider = try AppleProviders.make(Catalog.appleOnDevice)
        let host = try MCPToolHost(paths: store.paths)
        let start = Date()
        let report = try await Pipelines(provider: provider, model: "system", host: host, store: store).processLecture(materialId: mid) { print("progress:", $0) }
        print("Apple on-device: \(report.requests) requests in \(Int(Date().timeIntervalSince(start))) s")
        print(report.summary)
        print("warnings:", report.warnings)
        print("counts:", report.counts)
        XCTAssertGreaterThanOrEqual(report.counts["concepts"] ?? 0, 2)
        XCTAssertNotNil(store.material(mid)?.processedAt)
        #else
        throw XCTSkip("No FoundationModels")
        #endif
    }

    func testAppleOnDeviceChatsWithTools() async throws {
        #if canImport(FoundationModels)
        try XCTSkipUnless(AppleProviders.availability(Catalog.appleOnDevice).available)
        let store = try makeStore(file: true)
        let ids = try seedCourses(store)
        _ = try store.saveAssignment(Assignment(courseId: ids.hm, title: "Pricing report", kind: .report, dueAt: Date().addingTimeInterval(3 * 86_400), weightPct: 30))
        let provider = try AppleProviders.make(Catalog.appleOnDevice)
        var messages: [ChatMessage] = [.system(Prompts.studyRules), .user("What do I have due this week? Use the tools.")]
        let tools = LockedBox<[String]>([])
        let (reply, _) = try await AgentLoop(provider: provider, model: "system", host: try MCPToolHost(paths: store.paths, allowed: AITask.freeChatTools)).run(&messages) { e in
            if case .toolStarted(let n) = e { tools.value.append(n) }
        }
        print("tools:", tools.value, "reply:", reply.text)
        XCTAssertFalse(tools.value.isEmpty, "the model used a Study Tracker tool")
        XCTAssertTrue(reply.text.localizedCaseInsensitiveContains("pricing"))
        #else
        throw XCTSkip("No FoundationModels")
        #endif
    }
}
