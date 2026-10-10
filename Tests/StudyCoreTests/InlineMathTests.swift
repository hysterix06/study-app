import XCTest
@testable import StudyCore

final class InlineMathTests: XCTestCase {
    func testSentencesKeepTheirWordsAndMarkTheMaths() {
        let runs = InlineMath.runs("where $P^*$ is the price and $Q_d$ the quantity")
        XCTAssertEqual(runs, [
            .init("where ", math: false), .init("P"), .init("*", .sup), .init(" is the price and ", math: false),
            .init("Q"), .init("d", .sub), .init(" the quantity", math: false),
        ])
        XCTAssertEqual(InlineMath.runs("costs $5 and $6"), [.init("costs ", math: false), .init("5 and "), .init("6", math: false)],
                       "a lone dollar pair is read as maths, as LaTeX would")
        XCTAssertEqual(InlineMath.runs("no maths here"), [.init("no maths here", math: false)])
        XCTAssertEqual(InlineMath.runs("an open $ sign"), [.init("an open $ sign", math: false)])
    }

    func testCommonNotationBecomesUnicode() {
        XCTAssertEqual(InlineMath.plain(#"\frac{\Delta Q}{Q} \times 100"#), "ΔQ/Q × 100")
        XCTAssertEqual(InlineMath.plain(#"\frac{a+b}{2}"#), "(a+b)/2")
        XCTAssertEqual(InlineMath.plain(#"x^2 + y_{1}"#), "x² + y₁")
        XCTAssertEqual(InlineMath.plain(#"e^{rt}"#), "e^(rt)", "no Unicode superscript r: written out")
        XCTAssertEqual(InlineMath.plain(#"\bar{x} \le \mu"#), "x̄ ≤ μ")
        XCTAssertEqual(InlineMath.plain(#"\text{MR} = \text{MC}"#), "MR = MC")
        XCTAssertEqual(InlineMath.plain(#"\sqrt{2} \approx 1.41"#), "√2 ≈ 1.41")
        XCTAssertEqual(InlineMath.plain(#"\left( P^* \right)"#), "( P* )")
    }

    func testUnknownCommandsShowTheirName() {
        XCTAssertEqual(InlineMath.plain(#"\mathbb{R}"#), "ℝ")
        XCTAssertEqual(InlineMath.plain(#"\foo"#), "foo")
    }
}
