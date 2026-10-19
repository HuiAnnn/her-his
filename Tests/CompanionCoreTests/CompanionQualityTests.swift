import XCTest
@testable import CompanionCore

final class CompanionQualityTests: XCTestCase {
    @MainActor func testQuestionsCannotBecomeFactsByClippingEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(fileURL: directory.appendingPathComponent("memory.json"), ownerID: "test")
        for (source, evidence) in [("你知道怎么学习吗？", "怎么学习"), ("我喜欢什么饮料？", "我喜欢"), ("我的生日是哪天", "我的生日"), ("我喜欢晚上散步吗？", "我喜欢晚上散步")] {
            XCTAssertFalse(try store.apply(candidates: [.init(key: source, content: evidence, kind: .preference, evidence: evidence)], source: source, expectedRevision: store.revision, enabled: true), source)
        }
        let source = "我喜欢晚上散步，有什么路线推荐？"
        XCTAssertTrue(try store.apply(candidates: [.init(key: "walking", content: "喜欢晚上散步", kind: .preference, evidence: "我喜欢晚上散步")], source: source, expectedRevision: store.revision, enabled: true))
        XCTAssertFalse(try store.apply(candidates: [.init(key: "route", content: "喜欢路线推荐", kind: .preference, evidence: "有什么路线推荐")], source: source, expectedRevision: store.revision, enabled: true))
        XCTAssertEqual(try MemoryStore(fileURL: directory.appendingPathComponent("memory.json"), ownerID: "test").memories.count, 1)
    }

    @MainActor func testDeclarativeQuestionWordsAndAlternativeDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        let store = try MemoryStore(fileURL: url, ownerID: "test")
        for source in ["我不怎么吃辣", "我喜欢什么都不加的咖啡"] {
            XCTAssertTrue(try store.apply(candidates: [.init(key: source, content: source, kind: .preference, evidence: source)], source: source, expectedRevision: store.revision, enabled: true))
        }
        for source in ["我的生日是6月18日，还是6月19日？", "我的生日是6月18日，还是6月19日"] {
            for (key, evidence) in [("birthday_first", "我的生日是6月18日"), ("birthday_second", "6月19日")] {
                XCTAssertFalse(try store.apply(candidates: [.init(key: key, content: evidence, kind: .event, evidence: evidence)], source: source, expectedRevision: store.revision, enabled: true))
            }
        }
        XCTAssertTrue(try store.apply(candidates: [.init(key: "birthday", content: "生日是6月18日", kind: .event, evidence: "我的生日是6月18日")], source: "我的生日是6月18日。还是聊点别的吧。", expectedRevision: store.revision, enabled: true))
        XCTAssertEqual(try MemoryStore(fileURL: url, ownerID: "test").memories.count, 3)
    }

    func testBothRealtimeProvidersKeepOlderBirthdayAndBoundary() throws {
        let old: [CompanionMemory] = [.init(key: "birthday", content: "生日是8月12日", kind: .event, updatedAt: .distantPast), .init(key: "advice", content: "不喜欢被连续追问", kind: .boundary, updatedAt: .distantPast)]
        let recent = (0..<30).map { CompanionMemory(key: "event_\($0)", content: "近期事件\($0)", kind: .event) }
        let config = RealtimeConfiguration(name: "小禾", model: "1.2.1.1", voice: "zh_female_xiaohe_jupiter_bigtts", memories: recent + old)
        let dialog = try XCTUnwrap(try DoubaoPacket.session(config)["dialog"] as? [String: Any])
        for text in [try XCTUnwrap(dialog["system_role"] as? String), try XCTUnwrap(config.session["instructions"] as? String)] {
            XCTAssertTrue(text.contains("生日是8月12日"))
            XCTAssertTrue(text.contains("不喜欢被连续追问"))
        }
        var disabled = config; disabled.memoryEnabled = false
        let disabledDialog = try XCTUnwrap(try DoubaoPacket.session(disabled)["dialog"] as? [String: Any])
        XCTAssertFalse(String(describing: disabledDialog).contains("生日是8月12日"))
    }
}
