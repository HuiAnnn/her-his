import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class CallHistoryControllerTests: XCTestCase {
    func testLocalGoodbyeIsSavedBeforePhoneHangup() async throws {
        let (controller, realtime, _, speech, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        realtime.enabled = false
        await controller.checkConnection()
        controller.startCall()
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.submit("晚安")
        XCTAssertEqual(controller.callHistory.calls.first?.lines.map(\.text), ["晚安"])
        XCTAssertNotNil(controller.callHistory.calls.first?.endedAt)
        XCTAssertFalse(controller.callInProgress)
        XCTAssertTrue(speech.spoken.isEmpty, "Do not invent an unheard farewell in phone mode")
    }
    func testHangupKeepsBothSidesAndNextCallStartsAnotherRecord() throws {
        let (controller, _, driver, _, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?()
        speak(driver, user: "我今天画了一幅画", reply: "画画时是什么感觉")
        controller.disableVoice()
        XCTAssertTrue(controller.lines.isEmpty)
        XCTAssertEqual(controller.callHistory.calls.first?.lines.map(\.role), ["user", "assistant"])
        XCTAssertNotNil(controller.callHistory.calls.first?.endedAt)
        controller.startCall(); driver.onReady?()
        speak(driver, user: "我想再聊一下", reply: "我在听")
        controller.disableVoice()
        XCTAssertEqual(controller.callHistory.calls.count, 2)
        let reopened = try CallHistoryStore(fileURL: directory.appendingPathComponent("call-history.json"), ownerID: NSUserName())
        XCTAssertEqual(reopened.calls.count, 2)
    }
    func testPrivateTurnAndUnknownSourceDoNotLeakThroughAssistantHistory() {
        let (controller, _, driver, _, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?()
        speak(driver, user: "不要保存，fictional-sensitive-detail", reply: "fictional-sensitive-detail我听到了")
        controller.disableVoice()
        let saved = controller.callHistory.calls.flatMap(\.lines).map(\.text).joined()
        XCTAssertFalse(saved.contains("fictional-sensitive-detail"))
        XCTAssertEqual(controller.callHistory.calls.first?.lines.count, 2)
        controller.startCall(); driver.onReady?()
        driver.event("response.created", ["response": ["id": "unknown"]])
        driver.event("response.output_audio_transcript.done", ["response_id": "unknown", "transcript": "fictional-unmatched-detail"])
        driver.event("output_audio_buffer.stopped", ["response_id": "unknown"])
        XCTAssertFalse(controller.callHistory.calls.flatMap(\.lines).contains { $0.text.contains("fictional-unmatched-detail") })
    }
    func testDisableAndDeleteDuringCallDoNotResumeSaving() throws {
        let (controller, _, driver, _, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?()
        speak(driver, user: "开头", reply: "听到了")
        controller.callHistory.setEnabled(false)
        controller.callHistory.setEnabled(true)
        speak(driver, user: "不再追加", reply: "不再保存")
        XCTAssertEqual(controller.callHistory.calls.first?.lines.count, 2)
        controller.disableVoice(); controller.startCall(); driver.onReady?()
        speak(driver, user: "新通话", reply: "新的回答")
        let id = try XCTUnwrap(controller.callHistory.calls.first?.id)
        controller.callHistory.delete(id)
        speak(driver, user: "不能复活", reply: "迟到内容")
        XCTAssertFalse(controller.callHistory.calls.contains { $0.id == id })
    }
    private func speak(_ driver: FakeRealtimeDriver, user: String, reply: String) {
        let item = UUID().uuidString, response = UUID().uuidString
        driver.event("input_audio_buffer.speech_started")
        driver.event("input_audio_buffer.committed", ["item_id": item])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": item, "transcript": user])
        driver.event("response.created", ["response": ["id": response]])
        driver.event("response.output_audio_transcript.done", ["response_id": response, "transcript": reply])
        driver.event("output_audio_buffer.stopped", ["response_id": response])
    }
}
