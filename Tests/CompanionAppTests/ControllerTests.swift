import XCTest
import AppKit
import CompanionCore
@testable import CompanionApp

@MainActor final class ControllerTests: XCTestCase {
    private func fixture() -> (CompanionController, FakeSpeech, FakeModel, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "HerHisTest-\(UUID().uuidString)")!
        let speech = FakeSpeech(), client = FakeModel()
        let cloudVoice = CloudVoiceOutput(defaults: defaults, credentials: TestCredentials(), player: TestAudioPlayer())
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memory.json"), speech: speech, defaults: defaults, cloudVoice: cloudVoice, clientFactory: { _ in client })
        return (controller, speech, client, directory, defaults)
    }
    func testWakeAndFollowingWordsStayOneTurnUntilEndpoint() async throws {
        let (controller, speech, client, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await controller.checkConnection()
        controller.enableVoice()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(speech.contextPhrases, ["小禾"])
        speech.onPartial?("小禾", false)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertTrue(speech.spoken.isEmpty)
        speech.onPartial?("小禾，今天", false)
        XCTAssertTrue(client.requests.isEmpty)
        speech.onPartial?("小禾，今天有点累", true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests.first?.last?.content, "今天有点累")
    }
    func testBackgroundSpeechGetsNewUtteranceWithoutOpeningConversation() async throws {
        let (controller, speech, client, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.enableVoice()
        try await Task.sleep(nanoseconds: 30_000_000)
        let resets = speech.resets
        speech.onPartial?("会议结束了", true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertGreaterThan(speech.resets, resets)
        XCTAssertFalse(controller.canEnd)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertTrue(speech.spoken.isEmpty)
    }
    func testPrivateTurnFailureCannotLeakIntoNextRequest() async throws {
        let (controller, _, client, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await controller.checkConnection()
        client.shouldFail = true
        controller.submit("不要保存：我喜欢凌晨散步")
        try await Task.sleep(nanoseconds: 30_000_000)
        client.shouldFail = false
        controller.submit("换个话题")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertFalse(client.requests[1].contains { $0.content.contains("凌晨散步") })
        XCTAssertTrue(controller.memories.isEmpty)
    }
    func testMutingRejectsDelayedModelOutputAndEndStaysMuted() async throws {
        let (controller, speech, client, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await controller.checkConnection()
        client.suspend = true
        controller.submit("今天有点累")
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.mute()
        client.pending?.resume(returning: ModelReply(reply: "旧回复"))
        client.pending = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(controller.lines.contains { $0.text == "旧回复" })
        XCTAssertTrue(speech.spoken.isEmpty)
        controller.endConversation()
        XCTAssertTrue(controller.isMuted)
    }
    func testListeningPreferenceSurvivesHistoryLimitUntilExplicitChange() async throws {
        let (controller, _, client, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await controller.checkConnection()
        controller.submit("只想让你听，不要给建议")
        try await Task.sleep(nanoseconds: 20_000_000)
        for index in 0..<26 {
            controller.submit("日常分享第\(index)句")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let messages = try XCTUnwrap(client.requests.last)
        XCTAssertTrue(messages.contains { ReplyPolicy.listeningPreference(in: $0.content) == true })
        XCTAssertLessThanOrEqual(messages.count, 24)
        controller.submit("现在可以给我建议了")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(try ReplyPolicy.enforce("要不要出去走走？", messages: client.requests.last!), "要不要出去走走？")
    }
    func testEndCancelsPendingVoicePermissionStartup() async throws {
        let (controller, speech, _, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        speech.suspendPermission = true
        controller.enableVoice(startConversation: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.endConversation()
        speech.permission?.resume()
        speech.permission = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(speech.isRunning)
        XCTAssertFalse(controller.canEnd)
    }
    func testDirectCallShowsConnectingWhilePermissionIsPending() async throws {
        let (controller, speech, _, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        speech.suspendPermission = true
        controller.startCall()
        XCTAssertEqual(controller.phase, .connecting)
        XCTAssertTrue(controller.callInProgress)
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.disableVoice()
        speech.permission?.resume(); speech.permission = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(speech.isRunning)
        XCTAssertEqual(controller.phase, .off)
        XCTAssertFalse(controller.callInProgress)
    }
    func testLocalPhoneCallHangupStopsCaptureAndPlayback() async throws {
        let (controller, speech, _, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertTrue(speech.isRunning)
        speech.speak("合成测试语音")
        controller.disableVoice()
        XCTAssertFalse(controller.callInProgress)
        XCTAssertFalse(speech.isRunning)
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertFalse(controller.wakeEnabled)
    }
    func testSleepCancelsPendingPermissionAndStopsLocalPlayback() async throws {
        let (controller, speech, _, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        speech.suspendPermission = true
        controller.startCall()
        try await Task.sleep(nanoseconds: 30_000_000)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        speech.permission?.resume(); speech.permission = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(speech.isRunning)
        XCTAssertFalse(controller.callInProgress)
        speech.suspendPermission = false
        controller.startCall()
        try await Task.sleep(nanoseconds: 30_000_000)
        speech.speak("合成声音")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertFalse(speech.isRunning)
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertFalse(controller.callInProgress)
    }
    func testModelFailureReturnsVoiceToWakeOnly() async throws {
        let (controller, speech, client, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await controller.checkConnection()
        controller.enableVoice(startConversation: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        client.shouldFail = true
        controller.submit("今天有点累")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.phase, .waiting)
        XCTAssertFalse(controller.canEnd)
        XCTAssertTrue(speech.isRunning)
        XCTAssertTrue(controller.lines.isEmpty)
        XCTAssertNotNil(controller.errorText)
    }
    func testAudioFailureDisablesWakeAndClearsConversation() async throws {
        let (controller, speech, _, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.enableVoice(startConversation: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        speech.onFailure?("设备已断开")
        XCTAssertFalse(controller.wakeEnabled)
        XCTAssertFalse(controller.canEnd)
        XCTAssertFalse(speech.isRunning)
        XCTAssertEqual(controller.phase, .unavailable)
    }
    func testMemoryControlsResetActiveRecognition() async throws {
        let (controller, speech, _, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.enableVoice()
        try await Task.sleep(nanoseconds: 30_000_000)
        let resets = speech.resets
        controller.clearMemories()
        XCTAssertGreaterThan(speech.resets, resets)
    }
    func testInterruptWhileMutedDoesNotPretendMicrophoneIsListening() async throws {
        let (controller, _, _, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.enableVoice(startConversation: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.mute()
        controller.interrupt()
        XCTAssertEqual(controller.phase, .muted)
    }
    func testPreviewCancelsPendingMicrophonePermissionStartup() async throws {
        let (controller, speech, _, directory, _) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        speech.suspendPermission = true
        controller.enableVoice()
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.previewVoice()
        speech.permission?.resume(); speech.permission = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(speech.isRunning)
        XCTAssertFalse(controller.wakeEnabled)
    }
}

@MainActor final class FakeSpeech: SpeechDriving {
    var onPartial: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlaybackFailure: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onSpeechFinished: (() -> Void)?
    var contextPhrases: [String] = []
    var isRunning = false
    var isSpeaking = false
    var spoken: [String] = []
    var resets = 0
    var suspendPermission = false
    var permission: CheckedContinuation<Void, Never>?
    func requestPermission() async throws {
        if suspendPermission { await withCheckedContinuation { permission = $0 } }
    }
    func start() throws { isRunning = true }
    func stop() { isRunning = false; isSpeaking = false }
    func resetRecognition() throws { resets += 1 }
    func speak(_ text: String) { spoken.append(text); isSpeaking = true }
    func stopSpeaking() { isSpeaking = false }
}
@MainActor final class FakeModel: ModelServing {
    var requests: [[ChatMessage]] = []
    var shouldFail = false
    var suspend = false
    var pending: CheckedContinuation<ModelReply, Error>?
    func health() async throws -> [String] { ["qwen3:4b"] }
    func respond(messages: [ChatMessage], memories: [CompanionMemory], name: String) async throws -> ModelReply {
        requests.append(messages)
        if shouldFail { throw ModelClientError.invalidResponse }
        if suspend { return try await withCheckedThrowingContinuation { pending = $0 } }
        return ModelReply(reply: "我在听。")
    }
}
