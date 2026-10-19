import XCTest
@testable import CompanionCore

final class WakeMatcherTests: XCTestCase {
    func testOnlyAnchoredNameWakes() {
        XCTAssertNil(WakeMatcher.remainder(in: "她叫小禾", name: "小禾"))
        XCTAssertEqual(WakeMatcher.remainder(in: "  小禾，今天有点累", name: "小禾"), "今天有点累")
        XCTAssertEqual(WakeMatcher.remainder(in: "小禾", name: "小禾"), "")
        XCTAssertNil(WakeMatcher.remainder(in: "hello", name: ""))
    }
    func testLatinNameRequiresWordBoundary() {
        XCTAssertNil(WakeMatcher.remainder(in: "Annabelle is here", name: "Ann"))
        XCTAssertEqual(WakeMatcher.remainder(in: "ANN, hello", name: "Ann"), "hello")
        XCTAssertEqual(WakeMatcher.remainder(in: "小禾今天很累", name: "小禾"), "今天很累")
    }
}
