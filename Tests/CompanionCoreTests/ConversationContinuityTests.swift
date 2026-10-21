import XCTest
@testable import CompanionCore

@MainActor final class ConversationContinuityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func call(_ texts: [(String, String)], name: String = "测试伙伴", age: TimeInterval = 60, ended: Bool = true) -> CallRecord {
        .init(id: UUID(), startedAt: now.addingTimeInterval(-age), endedAt: ended ? now : nil,
              companion: name, provider: "test", lines: texts.enumerated().map { index, pair in
            .init(id: UUID(), role: pair.0, text: pair.1, time: now.addingTimeInterval(-age + Double(index)))
        })
    }
    func testLatestCallKeepsSourceChronologyAndCorrection() {
        let previous = call([("user", "纸船项目原定周三"), ("assistant", "想怎样展示呢"), ("user", "更正，改到周五了")])
        let text = ConversationContinuity.prompt(calls: [call([("user", "更早的事")], age: 600), previous], companion: "测试伙伴", now: now)
        XCTAssertTrue(text.contains(previous.id.uuidString))
        XCTAssertTrue(text.contains(previous.lines[0].id.uuidString))
        XCTAssertTrue(text.contains("周三")); XCTAssertTrue(text.contains("周五"))
        if let old = text.range(of: "周三"), let new = text.range(of: "周五") { XCTAssertLessThan(old.lowerBound, new.lowerBound) }
        XCTAssertFalse(text.contains("更早的事"))
    }
    func testNoExpiredDifferentCharacterOrPreBarrierContext() {
        let list = [call([("user", "别人的故事")], name: "另一个伙伴"), call([("user", "久远故事")], age: 8 * 86400)]
        XCTAssertTrue(ConversationContinuity.prompt(calls: list, companion: "测试伙伴", now: now).isEmpty)
        XCTAssertTrue(ConversationContinuity.prompt(calls: [call([("user", "旧屏障前")])], companion: "测试伙伴", after: now, now: now).isEmpty)
        // A latest unfinished call must not cause fallback to an older story.
        XCTAssertTrue(ConversationContinuity.prompt(calls: [call([("user", "之前")], age: 500), call([("user", "未完成")], ended: false)], companion: "测试伙伴", now: now).isEmpty)
    }
    func testPrivacyGapDropsEarlierContextAndNeverLeavesOrphanAssistant() {
        let previous = call([("assistant", "孤立回答"), ("user", "旧安排"), ("assistant", "旧回复"),
                             ("user", "[隐私回合内容已省略]"), ("assistant", "私密回复"),
                             ("user", "新的安全话题"), ("assistant", "安全回答")])
        let text = ConversationContinuity.prompt(calls: [previous], companion: "测试伙伴", now: now)
        XCTAssertTrue(text.contains("新的安全话题"))
        for hidden in ["旧安排", "旧回复", "私密回复", "孤立回答", "已省略"] { XCTAssertFalse(text.contains(hidden)) }
        for privateText in ["不要保存，虚构秘密", "api_key=fictional-secret-value-123456", "[原话未就绪或隐私回合，回答文字已省略]"] {
            XCTAssertTrue(ConversationContinuity.prompt(calls: [call([("user", privateText), ("assistant", "泄露")])], companion: "测试伙伴", now: now).isEmpty)
        }
    }
    func testBoundedContiguousRecentTurnsNeverCutsLargeCorrection() {
        var pairs = (0..<15).map { ("user", "合成回合\($0)：" + String(repeating: "纸", count: 700)) }
        let text = ConversationContinuity.prompt(calls: [call(pairs)], companion: "测试伙伴", now: now)
        XCTAssertTrue(text.contains("合成回合14")); XCTAssertFalse(text.contains("合成回合0："))
        XCTAssertLessThanOrEqual(text.count, 7000)
        pairs.append(("user", String(repeating: "更正内容", count: 2000)))
        XCTAssertTrue(ConversationContinuity.prompt(calls: [call(pairs)], companion: "测试伙伴", now: now).isEmpty)
    }
}
