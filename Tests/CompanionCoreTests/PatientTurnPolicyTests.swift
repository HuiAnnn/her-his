import XCTest
@testable import CompanionCore

final class PatientTurnPolicyTests: XCTestCase {
    func testEachDocumentedHoldAndReleaseCommand() {
        for hold in ["等我想一下", "让我想想", "让我想一下", "先听我说", "我没说完", "我还没说完", "我还没有说完"] {
            for release in ["你说吧", "我说完了", "可以回答了", "你可以回答了", "好了，你说吧"] {
                var policy = PatientTurnPolicy()
                policy.consume(" \(hold)，还有事情要讲。 ")
                XCTAssertTrue(policy.isHolding, hold)
                policy.consume("现在有两个想法")
                XCTAssertTrue(policy.isHolding)
                policy.consume("\(release)。")
                XCTAssertFalse(policy.isHolding, release)
            }
        }
    }
    func testAmbiguousReleaseDoesNotGiveAwayFloor() {
        for text in ["我说完了以后才发现遗漏", "你说吧是不是一句命令", "我朋友说你说吧然后就走了", "我没说完", "不要回答了", "“你说吧”", "我说完了吗？"] {
            var policy = PatientTurnPolicy(); policy.consume("让我想想")
            policy.consume(text)
            XCTAssertTrue(policy.isHolding, text)
        }
    }
}
