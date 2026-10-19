import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class LiveMemorySyncTests: XCTestCase {
    func fact(_ content: String) -> CompanionMemory { .init(key: "tea", content: content, kind: .preference) }
    func testCoalescesLatestSnapshotAndNeverRestartsOrSpeaks() {
        let sync = LiveMemorySync(); var sent: [(RealtimeConfiguration, Int)] = []; var status = ""
        sync.onSend = { sent.append(($0, $1)) }; sync.onStatus = { status = $0 }
        sync.start(.init(name: "小禾")); sync.activate()
        XCTAssertTrue(sent.isEmpty)
        let first = fact("喜欢红茶"), latest = fact("喜欢绿茶")
        sync.update([first]); sync.update([latest]); sync.update([latest])
        XCTAssertEqual(sent.count, 1); XCTAssertTrue(sync.isWaiting)
        sync.acknowledge(sent[0].1)
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(sent[1].0.memories.first?.content, "喜欢绿茶")
        sync.acknowledge(sent[0].1)
        XCTAssertTrue(sync.isWaiting, "Old ACK must not confirm latest snapshot")
        sync.acknowledge(sent[1].1)
        XCTAssertFalse(sync.isWaiting); XCTAssertEqual(status, "记忆已同步当前对话")
        sync.update([latest]); XCTAssertEqual(sent.count, 2)
        sync.stop(); sync.update([first]); sync.acknowledge(sent[1].1)
        XCTAssertTrue(status.isEmpty); XCTAssertEqual(sent.count, 2)
    }
    func testRejectedCoalescedUpdateCannotBeReportedAsSynced() {
        let sync = LiveMemorySync(); var revisions: [Int] = [], status = ""; var settled = 0
        sync.onStatus = { status = $0 }; sync.onSettled = { settled += 1 }
        sync.onSend = { _, id in revisions.append(id); if revisions.count == 2 { sync.reject(id) } }
        sync.start(.init(name: "小禾")); sync.activate()
        sync.update([fact("喜欢茶")]); sync.update([fact("喜欢咖啡")])
        sync.acknowledge(revisions[0])
        XCTAssertTrue(status.contains("未确认")); XCTAssertEqual(settled, 0)
        sync.stop()
    }
    func testTransportStopDuringCoalescedSendCannotResurrectSyncedStatus() {
        let sync = LiveMemorySync(); var revisions: [Int] = [], status = ""; var settled = 0
        sync.onStatus = { status = $0 }; sync.onSettled = { settled += 1 }
        sync.onSend = { _, id in revisions.append(id); if revisions.count == 2 { sync.stop() } }
        sync.start(.init(name: "小禾")); sync.activate()
        sync.update([fact("喜欢茶")]); sync.update([fact("喜欢咖啡")])
        sync.acknowledge(revisions[0])
        XCTAssertTrue(status.isEmpty); XCTAssertEqual(settled, 0)
    }
    func testTimeoutDoesNotClaimSuccessOrAssociateLateAckWithAnotherUpdate() async throws {
        let sync = LiveMemorySync(timeout: 20_000_000); var sent: [Int] = []; var status = ""; var settled = 0
        sync.onSend = { _, id in sent.append(id) }; sync.onStatus = { status = $0 }; sync.onSettled = { settled += 1 }
        sync.start(.init(name: "小禾")); sync.activate(); sync.update([fact("喜欢茶")])
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(sync.isWaiting); XCTAssertTrue(status.contains("未确认")); XCTAssertEqual(settled, 0)
        sync.update([fact("喜欢咖啡")]); sync.acknowledge(sent[0])
        XCTAssertEqual(sent.count, 1); XCTAssertTrue(status.contains("未确认"))
        sync.stop()
    }
    func testTimeoutRetainsUnsentTextAndLateUpdateErrorDoesNotCloseVoice() async throws {
        let keys = TestCredentials(); try keys.save("synthetic")
        let driver = FakeRealtimeDriver(), sync = LiveMemorySync(timeout: 20_000_000)
        let session = RealtimeConversation(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: keys, driver: driver, memorySync: sync)
        defer { session.stop() }
        try session.start(configuration: .init(name: "小禾")); driver.onReady?()
        let stops = driver.stops
        session.updateMemories([fact("喜欢茶")]); session.sendText("我喜欢什么")
        let eventID = try XCTUnwrap(driver.sent.first?["event_id"] as? String)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(driver.sent.contains { $0["type"] as? String == "conversation.item.create" })
        driver.event("error", ["error": ["event_id": eventID, "code": "invalid_request_error"]])
        XCTAssertTrue(session.isActive); XCTAssertEqual(driver.stops, stops)
    }
    func testDisabledAndStoppedSessionCannotTransmitMemories() {
        let sync = LiveMemorySync(); var sends = 0
        sync.onSend = { _, _ in sends += 1 }
        sync.start(.init(name: "小禾", memoryEnabled: false)); sync.activate()
        sync.update([fact("喜欢茶")]); sync.retrieve("我喜欢喝什么")
        XCTAssertEqual(sends, 0)
        sync.start(.init(name: "小禾")); sync.update([fact("喜欢茶")]); XCTAssertEqual(sends, 0)
        sync.stop(); sync.activate(); XCTAssertEqual(sends, 0)
    }
    func testTypedQuestionWaitsForMatchingContextAck() throws {
        let keys = TestCredentials(); try keys.save("synthetic")
        let driver = FakeRealtimeDriver()
        let session = RealtimeConversation(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: keys, driver: driver)
        defer { session.stop() }
        let old = CompanionMemory(key: "walking", content: "喜欢晚上散步", kind: .preference, updatedAt: .distantPast)
        let other = (0..<30).map { CompanionMemory(key: "event_\($0)", content: "活动\($0)", kind: .event) }
        try session.start(configuration: .init(name: "小禾", memories: other + [old])); driver.onReady?()
        session.sendText("我一般什么时候出去走走？")
        XCTAssertEqual(driver.sent.count, 1)
        let update = try XCTUnwrap(driver.sent.first?["session"] as? [String: Any])
        let instructions = try XCTUnwrap(update["instructions"] as? String)
        XCTAssertTrue(instructions.contains("喜欢晚上散步"))
        driver.event("session.updated", ["session": ["instructions": "stale"]])
        XCTAssertEqual(driver.sent.count, 1)
        driver.event("session.updated", ["session": ["instructions": instructions]])
        XCTAssertEqual(driver.sent.map { $0["type"] as? String ?? "" }, ["session.update", "conversation.item.create", "response.create"])
        XCTAssertEqual(driver.starts, 1)
    }
    func testSpeechOrStopCancelsDeferredTypedQuestion() throws {
        for stop in [false, true] {
            let keys = TestCredentials(); try keys.save("synthetic")
            let driver = FakeRealtimeDriver()
            let session = RealtimeConversation(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: keys, driver: driver)
            try session.start(configuration: .init(name: "小禾")); driver.onReady?()
            session.updateMemories([fact("喜欢茶")]); session.sendText("记得吗")
            let instructions = (driver.sent[0]["session"] as? [String: Any])?["instructions"] as? String ?? ""
            if stop { session.stop() } else { driver.event("input_audio_buffer.speech_started") }
            driver.event("session.updated", ["session": ["instructions": instructions]])
            XCTAssertFalse(driver.sent.contains { $0["type"] as? String == "conversation.item.create" })
            session.stop()
        }
    }
    func testPersistedFactTravelsThroughRealDoubaoProtocolWithoutRestart() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, keys = TestCredentials()
        try keys.save("synthetic-only")
        let driver = MemoryProtocolHarness()
        let session = RealtimeConversation(defaults: defaults, doubaoCredentials: keys, driver: FakeRealtimeDriver(), doubaoDriver: driver)
        session.provider = .doubao; session.enabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memory.json"), speech: FakeSpeech(), defaults: defaults, realtime: session)
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.enableVoice(startConversation: true)
        try driver.wire.receive(packet(450, ["question_id": "q1"]))
        try driver.wire.receive(packet(451, ["results": [["text": "我的生日是八月十二日。", "is_interim": false]]]))
        try driver.wire.receive(packet(459, [:]))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.memories.first?.key, "birthday")
        XCTAssertEqual(driver.packets.map(\.event), [201])
        XCTAssertTrue(String(decoding: driver.packets[0].payload, as: UTF8.self).contains("八月十二日"))
        XCTAssertTrue(session.memoryContextStatus.contains("正在同步"))
        try driver.wire.receive(packet(251, [:]))
        XCTAssertEqual(session.memoryContextStatus, "记忆已同步当前对话")
        try driver.wire.receive(packet(450, ["question_id": "q2"]))
        try driver.wire.receive(packet(451, ["results": [["text": "我的生日是哪天", "is_interim": false]]]))
        try driver.wire.receive(packet(459, [:]))
        XCTAssertEqual(driver.starts, 1); XCTAssertEqual(driver.packets.map(\.event), [201])
        XCTAssertTrue(session.isActive)
    }
    func testQueuedUpdateCannotConsumeDuplicateAckBeforeDispatch() async throws {
        var sent = 0, confirmed: [Int] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let driver = DoubaoRealtime(packetSink: { _ in
            sent += 1
            if sent == 1 { await withCheckedContinuation { releaseFirst = $0 } }
        })
        defer { releaseFirst?.resume(); driver.stop() }
        let config = RealtimeConfiguration(name: "小禾", model: "1.2.1.1", voice: "zh_female_xiaohe_jupiter_bigtts")
        driver.onEvent = { event in
            if event["type"] as? String == "memory_context.updated", let id = event["revision"] as? Int {
                confirmed.append(id)
                if id == 1 { driver.updateMemoryContext(config, revision: 2) }
            }
        }
        try driver.receive(packet(150, ["dialog_id": "dialog"]))
        driver.updateMemoryContext(config, revision: 1)
        try driver.receive(packet(251, [:]))
        XCTAssertTrue(confirmed.isEmpty, "Queued is not dispatched")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sent, 1)
        try driver.receive(packet(251, [:])); try driver.receive(packet(251, [:]))
        XCTAssertEqual(confirmed, [1]); XCTAssertEqual(sent, 1)
        releaseFirst?.resume(); releaseFirst = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sent, 2)
        try driver.receive(packet(251, [:])); XCTAssertEqual(confirmed, [1, 2])
    }
    private func packet(_ event: Int, _ body: [String: Any]) throws -> DoubaoPacket {
        var bytes = try DoubaoPacket.encode(event: event, sessionID: "", payload: JSONSerialization.data(withJSONObject: body))
        bytes[1] = 0x94
        return try DoubaoPacket.decode(bytes)
    }
    func testDoubaoUpdateUsesExistingDialogAndVoiceThenConfirmsOnce() async throws {
        var packets: [DoubaoPacket] = [], events: [[String: Any]] = []
        let driver = DoubaoRealtime(packetSink: { data in
            var bytes = data; bytes[1] = 0x94
            packets.append(try! DoubaoPacket.decode(bytes))
        })
        defer { driver.stop() }
        driver.onEvent = { events.append($0) }
        let started = try packet(150, ["dialog_id": "existing-dialog"])
        try driver.receive(started)
        let config = RealtimeConfiguration(name: "小禾", model: "1.2.1.1", voice: "zh_female_xiaohe_jupiter_bigtts", memories: [fact("喜欢雨声")])
        driver.updateMemoryContext(config, revision: 7)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(packets.map(\.event), [201])
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: packets[0].payload) as? [String: Any])
        let dialog = try XCTUnwrap(body["dialog"] as? [String: Any]), tts = try XCTUnwrap(body["tts"] as? [String: Any])
        XCTAssertEqual(dialog["dialog_id"] as? String, "existing-dialog")
        XCTAssertTrue((dialog["system_role"] as? String ?? "").contains("喜欢雨声"))
        XCTAssertFalse((dialog["speaking_style"] as? String ?? "").isEmpty)
        XCTAssertEqual(tts["speaker"] as? String, config.voice)
        XCTAssertEqual((tts["audio_config"] as? [String: Any])?["format"] as? String, "pcm_s16le")
        let ack = try packet(251, [:])
        try driver.receive(ack); try driver.receive(ack)
        XCTAssertEqual(events.filter { $0["type"] as? String == "memory_context.updated" }.count, 1)
        XCTAssertEqual(events.last?["revision"] as? Int, 7)
    }
}

@MainActor private final class MemoryProtocolHarness: RealtimeDriving {
    var onReady: (() -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var starts = 0
    var packets: [DoubaoPacket] = []
    lazy var wire = DoubaoRealtime(packetSink: { [weak self] data in
        var bytes = data; bytes[1] = 0x94
        self?.packets.append(try! DoubaoPacket.decode(bytes))
    })
    func start(key: String, configuration: RealtimeConfiguration) {
        starts += 1
        wire.onReady = { [weak self] in self?.onReady?() }
        wire.onEvent = { [weak self] in self?.onEvent?($0) }
        wire.onFailure = { [weak self] in self?.onFailure?($0) }
        var bytes = try! DoubaoPacket.encode(event: 150, sessionID: "", payload: Data("{\"dialog_id\":\"same-dialog\"}".utf8)); bytes[1] = 0x94
        try! wire.receive(DoubaoPacket.decode(bytes))
    }
    func updateMemoryContext(_ configuration: RealtimeConfiguration, revision: Int) { wire.updateMemoryContext(configuration, revision: revision) }
    func send(_ event: [String: Any]) { wire.send(event) }
    func interrupt() { wire.interrupt() }
    func stop() { wire.stop() }
}
