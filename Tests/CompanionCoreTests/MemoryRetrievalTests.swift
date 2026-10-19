import XCTest
@testable import CompanionCore

final class MemoryRetrievalTests: XCTestCase {
    func testOldRelevantFactAndNewFactSurviveBusyHistory() {
        let old = CompanionMemory(key: "walking", content: "习惯在晚上散步", kind: .preference, updatedAt: .distantPast)
        let new = CompanionMemory(key: "tea", content: "只喝无糖绿茶", kind: .preference, updatedAt: .distantPast)
        let other = (0..<40).map { CompanionMemory(key: "event_\($0)", content: "参加活动\($0)", kind: .event) }
        let bank = other + [old, new]
        XCTAssertFalse(MemoryContext.select(bank).contains(old))
        let selected = MemoryContext.select(bank, query: "我一般什么时候出去走走？", recentKeys: ["tea"])
        XCTAssertEqual(selected.first?.id, old.id)
        XCTAssertTrue(selected.contains(new)); XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(MemoryContext.select(bank, limit: 1, query: "我喜欢什么饮品").first?.id, new.id)
        XCTAssertFalse(MemoryContext.select(bank, query: "宇宙里黑洞是什么").contains(old))
    }
    func testBirthdaySynonymAndDeterministicBoundedSelection() {
        let birthday = CompanionMemory(key: "birthday", content: "生日是八月十二日", kind: .event, updatedAt: .distantPast)
        let items = (0..<25).map { CompanionMemory(key: "boundary_\($0)", content: "互动边界\($0)", kind: .boundary) } + [birthday]
        XCTAssertEqual(MemoryContext.select(items, limit: 1, query: "我是哪天出生的？").first?.id, birthday.id)
        XCTAssertTrue(MemoryContext.select(items, limit: 0).isEmpty)
        XCTAssertEqual(MemoryContext.json(items), MemoryContext.json(items))
    }
}
