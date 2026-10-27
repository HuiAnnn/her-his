import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class PatientTurnTests: XCTestCase {
    private func packet(_ event: Int, _ body: [String: Any] = [:], audio: Bool = false) throws -> DoubaoPacket {
        var bytes = try DoubaoPacket.encode(event: event, sessionID: "", payload: audio ? Data([0, 0]) : JSONSerialization.data(withJSONObject: body), audio: audio)
        bytes[1] = audio ? 0xB4 : 0x94
        return try DoubaoPacket.decode(bytes)
    }
    private func utterance(_ wire: DoubaoRealtime, _ text: String, id: String) throws {
        try wire.receive(packet(450, ["question_id": id]))
        try wire.receive(packet(451, ["results": [["text": text, "is_interim": false]]]))
        try wire.receive(packet(459))
    }
    private func response(_ wire: DoubaoRealtime, question: String, reply: String, textFirst: Bool = false) throws {
        let ids: [String: Any] = ["question_id": question, "reply_id": reply, "content": "合成回复", "text": "合成回复"]
        for event in textFirst ? [550, 350, 550, 559] : [350, 550, 559] { try wire.receive(packet(event, ids)) }
        try wire.receive(packet(352, audio: true))
        try wire.receive(packet(359, ids)); wire.playbackFinished(reply)
    }
    func testHoldAcrossTurnsRejectsTextFirstAndAudioFirstRepliesOnceThenReleases() async throws {
        var sent: [DoubaoPacket] = [], events: [[String: Any]] = []
        let wire = DoubaoRealtime(packetSink: { bytes in var bytes = bytes; bytes[1] = 0x94; sent.append(try DoubaoPacket.decode(bytes)) })
        defer { wire.stop() }
        wire.onEvent = { events.append($0) }
        try wire.receive(packet(150))
        try utterance(wire, "等我想一下", id: "q1")
        try response(wire, question: "q1", reply: "r1", textFirst: true)
        try utterance(wire, "我想尝试画图学习", id: "q2")
        try response(wire, question: "q2", reply: "r2")
        XCTAssertFalse(events.contains { $0["type"] as? String == "response.created" })
        XCTAssertFalse(events.contains { $0["type"] as? String == "output_audio_buffer.started" })
        XCTAssertEqual(events.filter { $0["type"] as? String == "conversation.item.input_audio_transcription.completed" }.count, 2)
        try utterance(wire, "你说吧", id: "q3")
        // Old packets cannot be revived by releasing the floor.
        try response(wire, question: "q1", reply: "r1")
        try response(wire, question: "q3", reply: "r3")
        let created = events.filter { $0["type"] as? String == "response.created" }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual((created.last?["response"] as? [String: Any])?["id"] as? String, "r3")
        XCTAssertEqual(events.filter { $0["type"] as? String == "response.output_audio_transcript.done" }.count, 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        let truncations = try sent.filter { $0.event == 513 }.map { try JSONSerialization.jsonObject(with: $0.payload) as! [String: Any] }
        XCTAssertEqual(truncations.compactMap { $0["item_id"] as? String }.sorted(), ["r1", "r2"])
        XCTAssertTrue(truncations.allSatisfy { $0["audio_end_ms"] as? Int == 0 })
    }
    func testOnlyFinalExplicitCommandsChangeFloorAndStopResetsIt() throws {
        let wire = DoubaoRealtime(); defer { wire.stop() }
        var held: [Bool] = []
        wire.onEvent = { if $0["type"] as? String == "turn.floor", let value = $0["holding"] as? Bool { held.append(value) } }
        try utterance(wire, "先听我说，我想整理一下", id: "q1")
        XCTAssertEqual(held, [true])
        try wire.receive(packet(450, ["question_id": "q2"]))
        try wire.receive(packet(451, ["results": [["text": "我说完了", "is_interim": true]]]))
        XCTAssertEqual(held, [true])
        try wire.receive(packet(451, ["results": [["text": "我说完了以后才想起还有别的", "is_interim": false]]]))
        XCTAssertEqual(held, [true])
        try utterance(wire, "我说完了。", id: "q3")
        XCTAssertEqual(held, [true, false])
        try utterance(wire, "让我想想", id: "q4")
        wire.stop()
        var created = 0
        wire.onEvent = { if $0["type"] as? String == "response.created" { created += 1 } }
        try utterance(wire, "你好", id: "new")
        try response(wire, question: "new", reply: "new-reply")
        XCTAssertEqual(created, 1)
    }
    func testQuotesNegationsAndQuestionsDoNotHold() throws {
        for text in ["她说让我想想，我觉得很烦", "不用等我想一下，你可以回答", "我没说完是不是一种借口？", "“先听我说”，这是她的原话", "如果我说先听我说，你会怎么做", "先听我说是什么意思？"] {
            let wire = DoubaoRealtime(); var created = 0
            wire.onEvent = { if $0["type"] as? String == "response.created" { created += 1 } }
            try utterance(wire, text, id: "q")
            try response(wire, question: "q", reply: "r")
            XCTAssertEqual(created, 1, text); wire.stop()
        }
    }
    func testHeldTurnOutlivesReplyDeadlineThenReleaseRestoresDeadline() async throws {
        let (session, driver, _) = ResponseWaitTests().fixture()
        let wire = DoubaoRealtime(); defer { wire.stop(); session.stop() }
        var failure: String?
        session.onFailure = { failure = $0 }
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        wire.onEvent = driver.onEvent
        try wire.receive(packet(150))
        try utterance(wire, "我还没说完", id: "q1")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(failure); XCTAssertEqual(session.state, .listening)
        XCTAssertTrue(session.turnHoldMessage.contains("你说吧"))
        XCTAssertTrue(session.responseWaitMessage.isEmpty)
        try utterance(wire, "还有一点我在想", id: "q2")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(failure); XCTAssertTrue(session.isActive)
        try utterance(wire, "可以回答了", id: "q3")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(failure); XCTAssertFalse(session.isActive)
    }
    func testTypedReleaseRestoresDeadlineWithoutSpeechStoppedEvent() async throws {
        let (session, driver, _) = ResponseWaitTests().fixture()
        let wire = DoubaoRealtime(); defer { wire.stop(); session.stop() }
        try session.start(configuration: .init(name: "Companion", memoryEnabled: false)); driver.onReady?()
        wire.onEvent = driver.onEvent; driver.onSend = wire.send
        try wire.receive(packet(150))
        session.sendText("让我想想")
        try wire.receive(packet(553, ["question_id": "q1"]))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(session.isActive); XCTAssertFalse(session.turnHoldMessage.isEmpty)
        session.sendText("你说吧")
        XCTAssertTrue(session.turnHoldMessage.isEmpty)
        try wire.receive(packet(553, ["question_id": "q2"]))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(session.isActive, "Text release must regain the unanswered reply deadline")
    }
    func testHoldCancelsExistingWaitAndRedialResetsUI() async throws {
        let (session, driver, _) = ResponseWaitTests().fixture()
        defer { session.stop() }
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        ResponseWaitTests().utterance(driver)
        driver.event("turn.floor", ["holding": true])
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(session.state, .listening)
        XCTAssertTrue(session.responseWaitMessage.isEmpty)
        session.stop()
        XCTAssertTrue(session.turnHoldMessage.isEmpty)
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        ResponseWaitTests().utterance(driver)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(session.isActive)
    }
}
