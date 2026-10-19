import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class RealtimeConversationTests: XCTestCase {
    func fixture() -> (RealtimeConversation, FakeRealtimeDriver) {
        let driver = FakeRealtimeDriver()
        let keys = TestCredentials(); try! keys.save("test-key")
        return (RealtimeConversation(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: keys, driver: driver), driver)
    }
    func testStopRejectsLateReadyTranscriptAndTools() throws {
        let (session, driver) = fixture()
        var heard: [String] = []; session.onUserTranscript = { heard.append($0) }
        try session.start(configuration: .init(name: "小禾"))
        let oldReady = driver.onReady, oldEvent = driver.onEvent
        session.stop()
        oldReady?(); oldEvent?(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "late private words"])
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(heard.isEmpty)
        XCTAssertTrue(driver.sent.isEmpty)
    }
    func testReadyDoesNotSolicitResponseUntilUserSpeaks() throws {
        let (session, driver) = fixture()
        try session.start(configuration: .init(name: "小禾"))
        driver.onReady?()
        XCTAssertEqual(session.state, .listening)
        XCTAssertTrue(driver.sent.isEmpty)
    }
    func testToolWaitsForMatchingTranscriptionAndExecutesOnce() throws {
        let (session, driver) = fixture()
        var sources: [String] = []
        session.onMemoryUpdate = { _, source in sources.append(source); return "saved" }
        try session.start(configuration: .init(name: "小禾")); driver.onReady?()
        driver.event("input_audio_buffer.committed", ["item_id": "u1"])
        driver.event("response.created", ["response": ["id": "r1"]])
        let done: [String: Any] = ["response": ["id": "r1", "status": "completed", "output": [["type": "function_call", "call_id": "c1", "name": "update_memory", "arguments": "{}"]]]]
        driver.event("response.done", done)
        XCTAssertTrue(sources.isEmpty)
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "u1", "transcript": "我喜欢雨声"])
        driver.event("response.done", done)
        XCTAssertEqual(sources, ["我喜欢雨声"])
        XCTAssertEqual(driver.sent.filter { $0["type"] as? String == "response.create" }.count, 1)
    }
    func testStopBeforeResponseCreatedRejectsLateCaptionAndMemory() throws {
        let (session, driver) = fixture()
        var writes = 0, captions: [String] = []
        session.onMemoryUpdate = { _, _ in writes += 1; return "saved" }
        session.onAssistantTranscript = { captions.append($0) }
        try session.start(configuration: .init(name: "小禾")); driver.onReady?()
        session.sendText("我喜欢雨声")
        session.interrupt()
        driver.event("response.created", ["response": ["id": "late"]])
        driver.event("response.output_audio_transcript.done", ["response_id": "late", "transcript": "不该续播"])
        driver.event("output_audio_buffer.stopped", ["response_id": "late"])
        driver.event("response.done", ["response": ["id": "late", "status": "completed", "output": [["type": "function_call", "call_id": "lateCall", "name": "update_memory", "arguments": "{}"]]]])
        XCTAssertTrue(captions.isEmpty); XCTAssertEqual(writes, 0)
        session.stop()
    }
    func testOldTranscriptionFailureDoesNotRejectCurrentMemory() throws {
        let (session, driver) = fixture()
        var sources: [String] = []
        session.onMemoryUpdate = { _, text in sources.append(text); return "saved" }
        try session.start(configuration: .init(name: "小禾")); driver.onReady?()
        driver.event("input_audio_buffer.committed", ["item_id": "u1"])
        driver.event("input_audio_buffer.speech_started")
        driver.event("input_audio_buffer.committed", ["item_id": "u2"])
        driver.event("response.created", ["response": ["id": "r2"]])
        driver.event("response.done", ["response": ["id": "r2", "status": "completed", "output": [["type": "function_call", "call_id": "c2", "name": "update_memory", "arguments": "{}"]]]])
        driver.event("conversation.item.input_audio_transcription.failed", ["item_id": "u1"])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "u2", "transcript": "我喜欢雨声"])
        XCTAssertEqual(sources, ["我喜欢雨声"])
        session.stop()
    }
    func testNewSpeechInvalidatesPendingMemoryAndUnheardCaption() throws {
        let (session, driver) = fixture()
        var saved = false, spoken: [String] = []
        session.onMemoryUpdate = { _, _ in saved = true; return "saved" }
        session.onAssistantTranscript = { spoken.append($0) }
        try session.start(configuration: .init(name: "小禾")); driver.onReady?()
        driver.event("input_audio_buffer.committed", ["item_id": "u1"])
        driver.event("response.created", ["response": ["id": "r1"]])
        driver.event("response.output_audio_transcript.done", ["response_id": "r1", "transcript": "很长的未播放回答"])
        driver.event("response.done", ["response": ["id": "r1", "status": "completed", "output": [["type": "function_call", "call_id": "c1", "name": "update_memory", "arguments": "{}"]]]])
        driver.event("input_audio_buffer.speech_started")
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "u1", "transcript": "旧话"])
        driver.event("output_audio_buffer.stopped", ["response_id": "r1"])
        XCTAssertFalse(saved)
        XCTAssertTrue(spoken.isEmpty)
        session.stop()
    }
}

@MainActor final class FakeRealtimeDriver: RealtimeDriving {
    var onReady: (() -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var sent: [[String: Any]] = []
    var starts = 0, stops = 0, interruptions = 0
    func start(key: String, configuration: RealtimeConfiguration) { starts += 1 }
    func send(_ event: [String: Any]) { sent.append(event) }
    func interrupt() { interruptions += 1 }
    func stop() { stops += 1 }
    func event(_ type: String, _ data: [String: Any] = [:]) { var event = data; event["type"] = type; onEvent?(event) }
}
