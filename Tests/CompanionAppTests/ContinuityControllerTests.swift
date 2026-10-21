import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class ContinuityControllerTests: XCTestCase {
    func testRedialCarriesPreviousCallWithoutSolicitingSpeech() throws {
        let (controller, _, driver, _, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?()
        speak(driver, "我在做一个虚构的纸船项目，约好周三展示。")
        controller.disableVoice(); controller.startCall(); driver.onReady?()
        let instructions = try XCTUnwrap(driver.configurations.last?.session["instructions"] as? String)
        XCTAssertTrue(instructions.contains("纸船项目"))
        XCTAssertTrue(driver.sent.isEmpty, "Loading history must not create a user turn or ask the model to speak")
    }
    func testDeletingLoadedHistoryEndsContextAndDoesNotResurrectOnRedial() throws {
        let (controller, _, driver, _, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?(); speak(driver, "虚构的纸船项目")
        controller.disableVoice()
        let source = try XCTUnwrap(controller.callHistory.calls.first?.id)
        controller.startCall(); driver.onReady?()
        controller.callHistory.delete(source)
        XCTAssertFalse(controller.callInProgress)
        controller.startCall(); driver.onReady?()
        XCTAssertFalse((driver.configurations.last?.session["instructions"] as? String ?? "").contains("纸船项目"))
    }
    func testDisablingHistoryEndsLoadedContext() {
        let (controller, _, driver, _, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?(); speak(driver, "虚构故事的前半段")
        controller.disableVoice(); controller.startCall(); driver.onReady?()
        controller.callHistory.setEnabled(false)
        XCTAssertFalse(controller.callInProgress)
        controller.startCall()
        XCTAssertFalse((driver.configurations.last?.session["instructions"] as? String ?? "").contains("前半段"))
    }
    func testMemoryEditExcludesOldSourceOnRedial() throws {
        let (controller, realtime, driver, _, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?(); speak(driver, "我平时喜欢雨声")
        let args = #"{"memories":[{"key":"rain","content":"喜欢雨声","kind":"preference","evidence":"我平时喜欢雨声"}],"forgetKeys":[]}"#
        _ = realtime.onMemoryUpdate?(args, "我平时喜欢雨声")
        let memory = try XCTUnwrap(controller.memories.first)
        controller.disableVoice(); controller.startCall(); driver.onReady?()
        controller.editMemory(memory.id, content: "喜欢海浪声")
        XCTAssertFalse(controller.callInProgress)
        controller.startCall()
        let instructions = try XCTUnwrap(driver.configurations.last?.session["instructions"] as? String)
        XCTAssertTrue(instructions.contains("海浪声")); XCTAssertFalse(instructions.contains("雨声"))
        XCTAssertFalse(controller.callHistory.calls.isEmpty, "Invalidating recall must preserve history for viewing")
    }
    func testLocalPathKeepsOldContextSeparateFromCurrentUserEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, client = FakeModel()
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memory.json"), speech: FakeSpeech(), defaults: defaults, clientFactory: { _ in client })
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await controller.checkConnection()
        controller.submit("虚构纸船项目安排在周三")
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.disableVoice(); controller.submit("后来改时间了")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(client.continuities.last?.contains("纸船项目") == true)
        XCTAssertEqual(client.requests.last?.last?.content, "后来改时间了")
        controller.callHistory.setContinuityEnabled(false)
        controller.submit("重新开始")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(client.continuities.last, "")
    }
    func testRecallToggleBarrierSurvivesReloadAndUpgradeDoesNotRecallUntrackedOldHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("call-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let old = try CallHistoryStore(fileURL: path, ownerID: NSUserName())
        try old.begin(companion: "小禾", provider: "test", enabled: true, now: Date().addingTimeInterval(-60))
        try old.append(role: "user", text: "升级前可能已删除的偏好"); try old.finish()
        let model = CallHistoryModel(fileURL: path, defaults: defaults)
        XCTAssertTrue(model.continuity(companion: "小禾").isEmpty)
        model.begin(companion: "小禾", provider: "test"); model.append(role: "user", text: "新的虚构项目"); model.finish()
        XCTAssertTrue(model.continuity(companion: "小禾").contains("虚构项目"))
        model.setContinuityEnabled(false)
        let reloaded = CallHistoryModel(fileURL: path, defaults: defaults)
        XCTAssertFalse(reloaded.continuityEnabled)
        reloaded.setContinuityEnabled(true)
        XCTAssertTrue(reloaded.continuity(companion: "小禾").contains("虚构项目"))
        reloaded.excludePastFromRecall()
        XCTAssertTrue(CallHistoryModel(fileURL: path, defaults: defaults).continuity(companion: "小禾").isEmpty)
    }
    func testMemorySyncRetainsContinuityForBothProviders() throws {
        let sync = LiveMemorySync(); var sent: RealtimeConfiguration?
        sync.onSend = { config, _ in sent = config }
        let config = RealtimeConfiguration(name: "小禾", model: "1.2.1.1", voice: "zh_female_vv_jupiter_bigtts", continuity: "合成的前次话题")
        sync.start(config); sync.activate()
        sync.update([.init(key: "tea", content: "喜欢绿茶", kind: .preference)])
        let updated = try XCTUnwrap(sent)
        XCTAssertTrue((updated.session["instructions"] as? String ?? "").contains("合成的前次话题"))
        let dialog = try XCTUnwrap(try DoubaoPacket.memoryUpdate(updated, dialogID: "synthetic-dialog")["dialog"] as? [String: Any])
        XCTAssertTrue((dialog["system_role"] as? String ?? "").contains("合成的前次话题"))
        XCTAssertTrue((dialog["system_role"] as? String ?? "").contains("绿茶"))
        sync.stop()
    }
    func testDeletingSourceAlsoExcludesLaterCallThatRepeatedIt() throws {
        let (controller, _, driver, _, directory) = RealtimeControllerTests().fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); driver.onReady?(); speak(driver, "故事里的暗号是银色纸船")
        controller.disableVoice()
        let source = try XCTUnwrap(controller.callHistory.calls.first?.id)
        controller.startCall(); driver.onReady?(); speak(driver, "你刚才提到的银色纸船是那个暗号吗")
        controller.callHistory.delete(source)
        controller.startCall()
        XCTAssertFalse((driver.configurations.last?.session["instructions"] as? String ?? "").contains("银色纸船"))
        XCTAssertFalse(controller.callHistory.calls.isEmpty, "Later history remains viewable, but must not feed recall")
    }
    func speak(_ driver: FakeRealtimeDriver, _ text: String) {
        let id = UUID().uuidString
        driver.event("input_audio_buffer.committed", ["item_id": id])
        driver.event("conversation.item.input_audio_transcription.completed", ["item_id": id, "transcript": text])
    }
}
