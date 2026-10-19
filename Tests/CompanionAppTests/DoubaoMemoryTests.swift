import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class DoubaoMemoryTests: XCTestCase {
    func testBirthdayPersistsWithoutLocalModelOrRememberCommand() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, keys = TestCredentials(), driver = FakeRealtimeDriver()
        try keys.save("test")
        let realtime = RealtimeConversation(defaults: defaults, doubaoCredentials: keys, driver: driver, doubaoDriver: driver)
        realtime.provider = .doubao; realtime.enabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = CompanionController(dataURL: dir.appendingPathComponent("memory.json"), speech: FakeSpeech(), defaults: defaults, realtime: realtime, clientFactory: { _ in XCTFail("Explicit birthday should not need a model"); return SequencedMemoryModel() })
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: dir) }
        controller.setTestRecordingEnabled(true)
        controller.enableVoice(startConversation: true); driver.onReady?()
        driver.event("input_audio_buffer.committed", ["item_id": "birthday"])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "birthday", "transcript": "我出生于1995年6月18日。"])
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.memories.first?.content, "生日是1995年6月18日")
        let restored = try MemoryStore(fileURL: dir.appendingPathComponent("memory.json"), ownerID: NSUserName())
        XCTAssertEqual(restored.memories.first?.key, "birthday")
        let recorded = try Data(contentsOf: controller.testJournalURL)
        let entries = try JSONDecoder().decode([TestJournal.Entry].self, from: recorded)
        XCTAssertTrue(entries.contains { $0.kind == "user" && $0.text.contains("1995年6月18日") })
        XCTAssertTrue(entries.contains { $0.kind == "memory" && $0.text.contains("已保存") })
        driver.event("input_audio_buffer.committed", ["item_id": "late"])
        driver.event("response.created", ["response": ["id": "r-late"]])
        driver.event("response.output_audio_transcript.done", ["response_id": "r-late", "transcript": "你的私人信息是private-marker"])
        driver.event("output_audio_buffer.stopped", ["response_id": "r-late"])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "late", "transcript": "private-marker这句话不要保存"])
        let privateRecord = try Data(contentsOf: controller.testJournalURL)
        XCTAssertFalse(String(decoding: privateRecord, as: UTF8.self).contains("private-marker"))
        controller.setTestRecordingEnabled(false)
        controller.clearTestRecords()
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.testJournalURL.path))
        controller.setTestRecordingEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.testJournalURL.path))
    }
    func testConsecutiveTurnsDoNotCancelEarlierFacts() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, keys = TestCredentials(), driver = FakeRealtimeDriver()
        try keys.save("test")
        let realtime = RealtimeConversation(defaults: defaults, doubaoCredentials: keys, driver: driver, doubaoDriver: driver)
        realtime.provider = .doubao; realtime.enabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = SequencedMemoryModel()
        let controller = CompanionController(dataURL: dir.appendingPathComponent("memory.json"), speech: FakeSpeech(), defaults: defaults, realtime: realtime, clientFactory: { _ in model })
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: dir) }
        controller.enableVoice(startConversation: true); driver.onReady?()
        driver.event("input_audio_buffer.committed", ["item_id": "u1"])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "u1", "transcript": "我喜欢雨声"])
        try await Task.sleep(nanoseconds: 10_000_000)
        driver.event("input_audio_buffer.committed", ["item_id": "u2"])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "u2", "transcript": "我喜欢晚上散步"])
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(Set(controller.memories.map(\.key)), ["rain", "walking"])
    }
    func testExtractionSavesWithEvidenceButCannotWriteAfterMute() async throws {
        for mute in [false,true] {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!, keys = TestCredentials(), driver = FakeRealtimeDriver()
            try keys.save("test")
            let realtime = RealtimeConversation(defaults: defaults, doubaoCredentials: keys, driver: driver, doubaoDriver: driver)
            realtime.provider = .doubao; realtime.enabled = true
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = DoubaoMemoryModel()
            let controller = CompanionController(dataURL: dir.appendingPathComponent("memory.json"), speech: FakeSpeech(), defaults: defaults, realtime: realtime, clientFactory: { _ in model })
            controller.enableVoice(startConversation: true); driver.onReady?()
            driver.event("input_audio_buffer.committed", ["item_id": "u1"])
            driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "u1", "transcript": "我喜欢雨声"])
            try await Task.sleep(nanoseconds: 10_000_000)
            if mute { controller.mute() }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(controller.memories.count, mute ? 0 : 1)
            controller.shutdown(); try? FileManager.default.removeItem(at: dir)
        }
    }
}
@MainActor private final class DoubaoMemoryModel: ModelServing {
    func health() async throws -> [String] { ["qwen3:4b"] }
    func respond(messages: [ChatMessage], memories: [CompanionMemory], name: String) async throws -> ModelReply { XCTFail("Must not use text model for speech replies"); return .init(reply: "") }
    func memoryCandidates(source: String, existing: [CompanionMemory]) async throws -> [MemoryCandidate] {
        try? await Task.sleep(nanoseconds: 50_000_000)
        return [.init(key: "rain", content: "喜欢雨声", kind: .preference, evidence: "我喜欢雨声")]
    }
}

@MainActor private final class SequencedMemoryModel: ModelServing {
    func health() async throws -> [String] { ["qwen3:4b"] }
    func respond(messages: [ChatMessage], memories: [CompanionMemory], name: String) async throws -> ModelReply { throw ModelClientError.invalidResponse }
    func memoryCandidates(source: String, existing: [CompanionMemory]) async throws -> [MemoryCandidate] {
        try await Task.sleep(nanoseconds: 50_000_000)
        return [.init(key: source.contains("雨") ? "rain" : "walking", content: source, kind: .preference, evidence: source)]
    }
}
