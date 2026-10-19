import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class CloudVoiceTests: XCTestCase {
    func testSavingKeyUsesCredentialStoreAndClearsDraft() throws {
        let name = "VoiceTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = TestCredentials()
        let output = CloudVoiceOutput(defaults: defaults, credentials: credentials, player: TestAudioPlayer())
        output.keyDraft = "  fake-secret  "
        output.saveKey()
        XCTAssertEqual(try credentials.read(), "fake-secret")
        XCTAssertTrue(output.keyDraft.isEmpty)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("fake-secret") })
        output.removeKey()
        XCTAssertNil(try credentials.read())
        XCTAssertFalse(output.enabled)
    }

    func testStoppedGenerationNeverPlaysLateAudio() async throws {
        let pending = PendingVoiceResponse()
        let client = ElevenLabsClient { request in await pending.response(request) }
        let player = TestAudioPlayer()
        let defaults = UserDefaults(suiteName: "VoiceTest-\(UUID().uuidString)")!
        let output = CloudVoiceOutput(defaults: defaults, credentials: TestCredentials("fake"), client: client, player: player)
        output.voiceID = "voice"; output.modelID = "eleven_v3"
        var completionCount = 0
        output.play("旧回复") { _ in completionCount += 1 }
        await pending.waitUntilRequested()
        output.stop()
        await pending.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(player.playCount, 0)
        XCTAssertFalse(output.isBusy)
        XCTAssertEqual(completionCount, 1)
    }

    func testMissingKeyFinishesWithUsefulErrorWithoutPlayback() async throws {
        let player = TestAudioPlayer()
        let output = CloudVoiceOutput(defaults: UserDefaults(suiteName: "VoiceTest-\(UUID().uuidString)")!, credentials: TestCredentials(), player: player)
        let done = expectation(description: "Missing key reported")
        output.play("你好") { result in
            if case .failure(let error) = result { XCTAssertEqual(error as? CloudVoiceError, .missingKey) }
            else { XCTFail("Expected missing key error") }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertFalse(output.isBusy)
    }

    func testPlaybackFailureKeepsConversationAndMicrophone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let speech = FakeSpeech()
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memory.json"), speech: speech,
            defaults: UserDefaults(suiteName: "VoiceTest-\(UUID().uuidString)")!, clientFactory: { _ in FakeModel() })
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await controller.checkConnection()
        controller.enableVoice(startConversation: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.submit("你好")
        try await Task.sleep(nanoseconds: 30_000_000)
        speech.onPlaybackFailure?("语音额度不足")
        XCTAssertTrue(speech.isRunning)
        XCTAssertTrue(controller.canEnd)
        XCTAssertFalse(controller.lines.isEmpty)
        XCTAssertEqual(controller.errorText, "语音额度不足")
    }
}

@MainActor final class TestCredentials: VoiceCredentialStoring {
    var key: String?
    init(_ key: String? = nil) { self.key = key }
    func read() throws -> String? { key }
    func save(_ value: String) throws { key = value }
    func delete() throws { key = nil }
}

@MainActor final class TestAudioPlayer: VoiceAudioPlaying {
    var playCount = 0
    func play(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) throws { playCount += 1 }
    func stop() {}
}

private actor PendingVoiceResponse {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var request: URLRequest?
    func response(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        self.request = request
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilRequested() async { while continuation == nil { await Task.yield() } }
    func finish() {
        continuation?.resume(returning: (Data([1, 2, 3]), HTTPURLResponse(url: request!.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!))
        continuation = nil
    }
}
