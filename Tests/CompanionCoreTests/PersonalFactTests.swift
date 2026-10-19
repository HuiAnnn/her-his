import XCTest
@testable import CompanionCore

final class PersonalFactTests: XCTestCase {
    func testExplicitBirthdayNeedsNoRememberCommand() throws {
        for source in ["我的生日是六月十八日。", "我出生于1995年6月18日。", "我的生日是农历八月初三", "我是1995年6月18日出生的"] {
            let candidate = try XCTUnwrap(PersonalFacts.birthday(from: source))
            XCTAssertEqual(candidate.key, "birthday")
            XCTAssertTrue(source.contains(candidate.evidence))
            XCTAssertTrue(candidate.content.contains("生日"))
        }
        XCTAssertEqual(PersonalFacts.birthday(from: "我的生日是农历八月初三")?.content, "生日是农历八月初三")
    }
    func testNeverInfersDateFromMemoryInstructionsQuestionsOrOtherPeople() {
        for source in ["生日会保存到慢慢记得里面", "你记住我的生日了吗？", "我的生日是6月18日吗？", "如果我的生日是6月18日", "她说我的生日是6月18日", "我的生日是2月30日", "我的生日是6月18日，不要保存", "我朋友的生日是6月18日", "我的生日是6月18日，不对，是6月19日"] {
            XCTAssertNil(PersonalFacts.birthday(from: source), source)
        }
    }
    func testFastPathDefersAmbiguousAndMultipleFactUtterances() {
        for source in ["我的生日是6月18日，还是6月19日？", "我的生日是6月18日，我不太确定。", "我的生日是6月18日，不，是6月19日。", "我的生日是6月18日，我叫小林，我喜欢晚上散步。", "我喜欢散步，我的生日是6月18日。"] {
            XCTAssertNil(PersonalFacts.birthday(from: source), source)
        }
    }
    @MainActor func testStoreRejectsMetaClaimEvenWithLiteralEvidence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(fileURL: dir.appendingPathComponent("memory.json"), ownerID: "test")
        let source = "生日会保存到慢慢记得里面"
        XCTAssertFalse(try store.apply(candidates: [.init(key: "birthday_reminder", content: source, kind: .event, evidence: source)], source: source, expectedRevision: 0, enabled: true))
        XCTAssertTrue(store.memories.isEmpty)
        XCTAssertFalse(try store.apply(candidates: [.init(key: "birthday_reminder", content: "希望记录生日", kind: .event, evidence: source)], source: source, expectedRevision: 0, enabled: true))
    }
    @MainActor func testFactPlusSaveInstructionIsStillEligible() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(fileURL: dir.appendingPathComponent("memory.json"), ownerID: "test")
        let source = "我的生日是6月18日，请保存到慢慢记得里面。"
        XCTAssertFalse(MemoryPolicy.isStorageNarration(source))
        XCTAssertTrue(try store.apply(candidates: [.init(key: "birthday", content: "生日是6月18日", kind: .event, evidence: source)], source: source, expectedRevision: 0, enabled: true))
    }
}
