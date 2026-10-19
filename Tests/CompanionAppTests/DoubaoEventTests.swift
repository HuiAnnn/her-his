import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class DoubaoEventTests: XCTestCase {
    func testChatTextAppearsAfterPlaybackWhenTTSStartTextIsEmpty() throws {
        let driver = DoubaoRealtime(); var captions: [String] = []
        driver.onEvent = { if $0["type"] as? String == "response.output_audio_transcript.done", let text = $0["transcript"] as? String { captions.append(text) } }
        let ids: [String: Any] = ["question_id": "q", "reply_id": "r"]
        try driver.receive(packet(450, ["question_id": "q"]))
        try driver.receive(packet(350, ids.merging(["text": ""]) { _, v in v }))
        try driver.receive(packet(550, ids.merging(["content": "可以试试画图，"]) { _, v in v }))
        try driver.receive(packet(350, ids.merging(["text": "可以试试画图，"]) { _, v in v }))
        try driver.receive(packet(550, ids.merging(["content": "把概念连起来。"]) { _, v in v }))
        try driver.receive(packet(559, ids))
        XCTAssertTrue(captions.isEmpty, "Do not display unplayed speech")
        driver.playbackFinished("r")
        driver.playbackFinished("r")
        XCTAssertEqual(captions, ["可以试试画图，把概念连起来。"])
    }
    func testLateTextEmptyFallbackAndInterruptedReplies() throws {
        let driver = DoubaoRealtime(); var captions: [String] = []
        driver.onEvent = { if $0["type"] as? String == "response.output_audio_transcript.done", let text = $0["transcript"] as? String { captions.append(text) } }
        func send(_ event: Int, _ q: String, _ r: String, _ field: String = "content", _ text: String = "") throws {
            try driver.receive(packet(event, ["question_id": q, "reply_id": r, field: text]))
        }
        try send(450, "q1", "r1"); try send(350, "q1", "r1", "text", " ")
        driver.playbackFinished("r1")
        XCTAssertTrue(captions.isEmpty)
        try send(550, "q1", "r1", "content", "迟到但完整的字幕")
        try send(559, "q1", "r1")
        XCTAssertEqual(captions, ["迟到但完整的字幕"])
        try send(450, "q2", "r2"); try send(350, "q2", "r2", "text", "音频自带字幕")
        driver.playbackFinished("r2")
        XCTAssertEqual(captions.last, "音频自带字幕")
        try send(450, "q3", "r3"); try send(550, "q3", "r3", "content", "没有听完")
        driver.interrupt()
        try send(559, "q3", "r3"); driver.playbackFinished("r3")
        XCTAssertEqual(captions.count, 2)
        try send(450, "q4", "r4"); try send(550, "q3", "r3", "content", "旧轮迟到")
        driver.playbackFinished("r3")
        XCTAssertEqual(captions.count, 2)
    }
    func testReplyFlowsThroughConversationToVisibleLinesAndTestRecord() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, keys = TestCredentials()
        defaults.set(false, forKey: "memoryEnabled")
        try keys.save("synthetic-key")
        let transport = FakeRealtimeDriver(), driver = DoubaoRealtime()
        let session = RealtimeConversation(defaults: defaults, doubaoCredentials: keys, driver: transport, doubaoDriver: transport)
        session.provider = .doubao; session.enabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memories.json"), speech: FakeSpeech(), defaults: defaults, realtime: session)
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.setTestRecordingEnabled(true)
        controller.enableVoice(startConversation: true); transport.onReady?()
        driver.onEvent = { transport.onEvent?($0) }
        try driver.receive(packet(450, ["question_id": "q"]))
        try driver.receive(packet(451, ["results": [["text": "怎么学习", "is_interim": false]]]))
        try driver.receive(packet(459, [:]))
        let ids: [String: Any] = ["question_id": "q", "reply_id": "r"]
        try driver.receive(packet(350, ids.merging(["text": ""]) { _, v in v }))
        try driver.receive(packet(550, ids.merging(["content": "可以用图像联想。"]) { _, v in v }))
        try driver.receive(packet(559, ids))
        driver.playbackFinished("r")
        XCTAssertEqual(controller.lines.filter { $0.role == "assistant" }.map(\.text), ["可以用图像联想。"])
        let journal = try JSONDecoder().decode([TestJournal.Entry].self, from: Data(contentsOf: controller.testJournalURL))
        XCTAssertEqual(journal.filter { $0.kind == "assistant" }.map(\.text), ["可以用图像联想。"])
        transport.event("response.created", ["response": ["id": "empty"]])
        transport.event("response.output_audio_transcript.done", ["response_id": "empty", "transcript": " \n"])
        transport.event("output_audio_buffer.stopped", ["response_id": "empty"])
        XCTAssertEqual(controller.lines.filter { $0.role == "assistant" }.count, 1)
    }
    func packet(_ event: Int, _ body: [String: Any]) throws -> DoubaoPacket {
        var bytes = try DoubaoPacket.encode(event: event, sessionID: "", payload: JSONSerialization.data(withJSONObject: body)); bytes[1] = 0x94
        return try DoubaoPacket.decode(bytes)
    }
    func testSupersededTypedAcknowledgmentCannotRestoreOldReply() throws {
        let driver = DoubaoRealtime(); var replies: [String] = []
        driver.onEvent = { if $0["type"] as? String == "response.created", let response = $0["response"] as? [String: Any], let id = response["id"] as? String { replies.append(id) } }
        try driver.receive(packet(150, [:]))
        func text(_ value: String) { driver.send(["type": "conversation.item.create", "item": ["role": "user", "content": [["text": value]]]]) }
        text("第一句"); text("第二句")
        try driver.receive(packet(553, ["question_id": "old"]))
        try driver.receive(packet(350, ["question_id": "old", "reply_id": "r-old"]))
        XCTAssertTrue(replies.isEmpty)
        try driver.receive(packet(553, ["question_id": "new"]))
        try driver.receive(packet(350, ["question_id": "new", "reply_id": "r-new"]))
        XCTAssertEqual(replies, ["r-new"])
        driver.stop()
    }
    func testFinalTranscriptAndStaleReplyAfterBargeIn() throws {
        let driver = DoubaoRealtime(); var events: [[String: Any]] = []
        driver.onEvent = { events.append($0) }
        try driver.receive(packet(450, ["question_id": "q1"]))
        try driver.receive(packet(451, ["results": [["text": "我喜欢雨声", "is_interim": false]]]))
        try driver.receive(packet(459, [:]))
        XCTAssertEqual(events.last?["type"] as? String, "input_audio_buffer.speech_stopped")
        XCTAssertEqual(events.filter { $0["transcript"] != nil }.count, 1)
        try driver.receive(packet(350, ["question_id": "q1", "reply_id": "r1", "text": "嗯"]))
        try driver.receive(packet(450, ["question_id": "q2"]))
        try driver.receive(packet(350, ["question_id": "q1", "reply_id": "r1", "text": "旧回复"]))
        try driver.receive(packet(350, ["question_id": "q2", "reply_id": "r2", "text": "新回复"]))
        XCTAssertEqual(events.filter { $0["type"] as? String == "response.created" }.count, 2)
        driver.interrupt()
        try driver.receive(packet(350, ["question_id": "q2", "reply_id": "r3", "text": "迟到回复"]))
        XCTAssertEqual(events.filter { $0["type"] as? String == "response.created" }.count, 2)
    }
}
