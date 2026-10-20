import XCTest
import AppKit
import CompanionCore
@testable import CompanionApp

@MainActor final class RealtimeControllerTests: XCTestCase {
    func fixture() -> (CompanionController, RealtimeConversation, FakeRealtimeDriver, FakeSpeech, URL) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let keys = TestCredentials(); try! keys.save("test-key")
        let driver = FakeRealtimeDriver(), speech = FakeSpeech()
        let realtime = RealtimeConversation(defaults: defaults, credentials: keys, driver: driver); realtime.enabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memory.json"), speech: speech, defaults: defaults, realtime: realtime, clientFactory: { _ in FakeModel() })
        return (controller, realtime, driver, speech, directory)
    }
    func testStandbyKeepsAudioLocalUntilWakeThenSwitchesCapture() async throws {
        let (controller, _, driver, speech, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.enableVoice()
        try await Task.sleep(nanoseconds: 30_000_000)
        speech.onPartial?("背景中的一句话", true)
        XCTAssertEqual(driver.starts, 0)
        speech.onPartial?("小禾，今天有点累", true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertFalse(speech.isRunning)
        driver.onReady?()
        XCTAssertTrue(driver.sent.contains { ($0["item"] as? [String: Any])?["role"] as? String == "user" })
    }
    func testMuteClosesRealtimeAndLateCallbacksCannotRestoreIt() throws {
        let (controller, realtime, driver, _, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.enableVoice(startConversation: true)
        driver.onReady?(); let old = driver.onEvent
        controller.mute()
        old?(["type": "response.created", "response": ["id": "late"]])
        XCTAssertEqual(realtime.state, .idle)
        XCTAssertTrue(controller.isMuted)
        XCTAssertFalse(controller.microphoneRunning)
    }
    func testPhoneCallConnectsOnceAndHangupRejectsLateReady() {
        let (controller, realtime, driver, speech, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); controller.startCall()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(controller.phase, .connecting)
        XCTAssertTrue(controller.callInProgress)
        XCTAssertFalse(speech.isRunning)
        let lateReady = driver.onReady
        controller.disableVoice(); lateReady?()
        XCTAssertFalse(controller.callInProgress)
        XCTAssertFalse(controller.microphoneRunning)
        XCTAssertFalse(controller.wakeEnabled)
        XCTAssertEqual(realtime.state, .idle)
        controller.startCall(); driver.onReady?()
        XCTAssertEqual(driver.starts, 2)
        XCTAssertEqual(controller.phase, .listening)
    }
    func testPhoneCallGoodbyeStopsCaptureWithoutReturningToWakeMode() async throws {
        let (controller, realtime, driver, speech, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?()
        driver.event("input_audio_buffer.committed", ["item_id": "goodbye"])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "goodbye", "transcript": "先不聊了"])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(realtime.state, .idle)
        XCTAssertFalse(controller.callInProgress)
        XCTAssertFalse(speech.isRunning)
        XCTAssertFalse(controller.wakeEnabled)
    }
    func testFailedPhoneCallReturnsToIdleAndCanRetry() {
        let (controller, _, driver, _, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onFailure?("Synthetic connection failure")
        XCTAssertFalse(controller.callInProgress)
        XCTAssertFalse(controller.microphoneRunning)
        XCTAssertNotNil(controller.errorText)
        controller.startCall()
        XCTAssertEqual(driver.starts, 2)
        XCTAssertTrue(controller.callInProgress)
    }
    func testSleepEndsCallAndLateReadyCannotResumeIt() {
        let (controller, realtime, driver, speech, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall()
        let lateReady = driver.onReady
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        lateReady?()
        XCTAssertFalse(controller.callInProgress)
        XCTAssertFalse(controller.microphoneRunning)
        XCTAssertFalse(speech.isRunning)
        XCTAssertEqual(realtime.state, .idle)
        XCTAssertTrue(controller.errorText?.contains("休眠") == true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(driver.starts, 1)
        controller.startCall(); driver.onReady?()
        XCTAssertEqual(driver.starts, 2)
        XCTAssertEqual(controller.phase, .listening)
    }
    func testSleepWhileIdleDoesNotCreateAnError() {
        let (controller, _, _, _, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertNil(controller.errorText)
        XCTAssertFalse(controller.callInProgress)
    }
    func testRealtimeMemoryUsesRealStoreAndEditingClosesCloudContext() throws {
        let (controller, realtime, driver, _, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.enableVoice(startConversation: true); driver.onReady?()
        driver.event("input_audio_buffer.committed", ["item_id": "u1"])
        driver.event("response.created", ["response": ["id": "r1"]])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": "u1", "transcript": "我喜欢雨声"])
        let args = "{\"memories\":[{\"key\":\"rain\",\"content\":\"喜欢雨声\",\"kind\":\"preference\",\"evidence\":\"我喜欢雨声\"}],\"forgetKeys\":[]}"
        driver.event("response.done", ["response": ["id": "r1", "status": "completed", "output": [["type": "function_call", "name": "update_memory", "call_id": "c1", "arguments": args]]]])
        let memory = try XCTUnwrap(controller.memories.first)
        controller.editMemory(memory.id, content: "喜欢海浪声")
        XCTAssertEqual(realtime.state, .idle)
        XCTAssertEqual(controller.memories.first?.content, "喜欢海浪声")
    }
}
