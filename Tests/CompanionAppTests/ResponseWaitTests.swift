import XCTest
import Combine
import CompanionCore
@testable import CompanionApp

@MainActor final class ResponseWaitTests: XCTestCase {
    func fixture(_ provider: RealtimeProvider = .doubao) -> (RealtimeConversation, FakeRealtimeDriver, UserDefaults) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(provider.rawValue, forKey: "realtimeProvider")
        let keys = TestCredentials(); try! keys.save("synthetic")
        let driver = FakeRealtimeDriver()
        let session = RealtimeConversation(defaults: defaults, credentials: keys, doubaoCredentials: keys,
                                           driver: driver, doubaoDriver: driver,
                                           responseWarningDelay: 10_000_000, responseTimeout: 80_000_000)
        return (session, driver, defaults)
    }
    func utterance(_ driver: FakeRealtimeDriver, id: String = "u1") {
        driver.event("input_audio_buffer.speech_started")
        driver.event("input_audio_buffer.committed", ["item_id": id])
        driver.event("input_audio_buffer.speech_stopped")
    }
    func testUnansweredTurnWarnsThenEndsForBothProviders() async throws {
        for provider in [RealtimeProvider.doubao, .openAI] {
            let (session, driver, _) = fixture(provider)
            defer { session.stop() }
            let warning = expectation(description: "Waiting is visible")
            let failure = expectation(description: "Unanswered turn ends")
            let observer = session.$responseWaitMessage.dropFirst().filter { !$0.isEmpty }.sink { _ in warning.fulfill() }
            session.onFailure = { _ in failure.fulfill() }
            try session.start(configuration: .init(name: "Companion")); driver.onReady?()
            utterance(driver)
            driver.event("response.created", ["response": ["id": "r1"]])
            await fulfillment(of: [warning, failure], timeout: 1, enforceOrder: true)
            XCTAssertFalse(session.isActive); XCTAssertTrue(session.responseWaitMessage.isEmpty)
            observer.cancel()
        }
    }
    func testQuietConnectionAndUnfinishedUserSpeechDoNotTimeOut() async throws {
        let (session, driver, _) = fixture()
        defer { session.stop() }
        session.onFailure = { _ in XCTFail("Silence and speaking are not response waits") }
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertEqual(session.state, .listening)
        driver.event("input_audio_buffer.speech_started")
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertTrue(session.isActive); XCTAssertTrue(session.responseWaitMessage.isEmpty)
    }
    func testFirstAudioClearsWarningAndLongPlaybackDoesNotTimeOut() async throws {
        let (session, driver, _) = fixture()
        defer { session.stop() }
        let warning = expectation(description: "Warning before audio")
        let observer = session.$responseWaitMessage.filter { !$0.isEmpty }.sink { _ in warning.fulfill() }
        session.onFailure = { _ in XCTFail("Audio has already begun") }
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        utterance(driver); driver.event("response.created", ["response": ["id": "r1"]])
        await fulfillment(of: [warning], timeout: 1)
        driver.event("output_audio_buffer.started", ["response_id": "r1"])
        XCTAssertTrue(session.responseWaitMessage.isEmpty)
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertEqual(session.state, .speaking); observer.cancel()
    }
    func testNewSpeechAndHangupCancelOldDeadlineAcrossRedial() async throws {
        let (session, driver, _) = fixture()
        defer { session.stop() }
        session.onFailure = { _ in XCTFail("Old deadline cannot end a new input or call") }
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        utterance(driver); driver.event("input_audio_buffer.speech_started")
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertTrue(session.isActive); XCTAssertTrue(session.responseWaitMessage.isEmpty)
        utterance(driver, id: "u2"); session.stop()
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertEqual(session.state, .listening); XCTAssertTrue(session.responseWaitMessage.isEmpty)
    }
    func testOldAudioCannotCancelNewTurnDeadline() async throws {
        let (session, driver, _) = fixture()
        defer { session.stop() }
        let failure = expectation(description: "New unanswered turn still expires")
        session.onFailure = { _ in failure.fulfill() }
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        utterance(driver); driver.event("response.created", ["response": ["id": "old"]])
        utterance(driver, id: "u2")
        driver.event("output_audio_buffer.started", ["response_id": "old"])
        await fulfillment(of: [failure], timeout: 1)
        XCTAssertFalse(session.isActive)
    }
    func testEmptyCompletedOpenAIResponseReturnsToListening() async throws {
        let (session, driver, _) = fixture(.openAI)
        defer { session.stop() }
        session.onFailure = { _ in XCTFail("An intentional empty response has completed") }
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        utterance(driver); driver.event("response.created", ["response": ["id": "r1"]])
        driver.event("response.done", ["response": ["id": "r1", "status": "completed", "output": []]])
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertEqual(session.state, .listening); XCTAssertTrue(session.responseWaitMessage.isEmpty)
    }
    func testTimeoutStopsControllerCaptureAndAllowsRedial() async throws {
        let (session, driver, defaults) = fixture()
        session.enabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memory.json"), speech: FakeSpeech(), defaults: defaults, realtime: session)
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?(); utterance(driver)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(controller.callInProgress); XCTAssertFalse(controller.microphoneRunning)
        XCTAssertNotNil(controller.errorText)
        controller.startCall(); driver.onReady?()
        XCTAssertTrue(controller.callInProgress); XCTAssertEqual(session.state, .listening)
    }
    func testDoubaoPCMIdentifiesReplyAndCancelsTimeout() async throws {
        let (session, driver, _) = fixture()
        let wire = DoubaoRealtime()
        defer { wire.stop(); session.stop() }
        session.onFailure = { _ in XCTFail("Real PCM packets must cancel the response wait") }
        try session.start(configuration: .init(name: "Companion")); driver.onReady?()
        wire.onEvent = driver.onEvent
        func packet(_ event: Int, _ body: [String: Any] = [:], audio: Bool = false) throws -> DoubaoPacket {
            let payload = audio ? Data([0, 0]) : try JSONSerialization.data(withJSONObject: body)
            var bytes = try DoubaoPacket.encode(event: event, sessionID: "", payload: payload, audio: audio)
            bytes[1] = audio ? 0xB4 : 0x94
            return try DoubaoPacket.decode(bytes)
        }
        try wire.receive(packet(150))
        try wire.receive(packet(450, ["question_id": "u1"]))
        try wire.receive(packet(459))
        try wire.receive(packet(350, ["question_id": "u1", "reply_id": "r1", "text": "合成测试"]))
        try wire.receive(packet(352, audio: true))
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertEqual(session.state, .speaking); XCTAssertTrue(session.responseWaitMessage.isEmpty)
    }
}
