import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class ConnectionHeartbeatTests: XCTestCase {
    func testUnansweredProbeFailsOnceWithoutWaitingForTransportCallback() async {
        let failed = expectation(description: "Unanswered probe closes call")
        let heartbeat = ConnectionHeartbeat(interval: 1_000_000, timeout: 20_000_000)
        var probes = 0, failures = 0
        heartbeat.start(probe: { _ in probes += 1 }, onFailure: { failures += 1; failed.fulfill() })
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(probes, 1); XCTAssertEqual(failures, 1)
        heartbeat.stop()
    }
    func testQuietHealthyConnectionKeepsCheckingWithoutConversationEvents() async {
        let checked = expectation(description: "Healthy silent connection"); checked.expectedFulfillmentCount = 3
        let heartbeat = ConnectionHeartbeat(interval: 1_000_000, timeout: 200_000_000)
        var count = 0
        heartbeat.start(probe: { reply in
            count += 1; reply(true); checked.fulfill()
            if count == 3 { heartbeat.stop() }
        }, onFailure: { XCTFail("Silence must not be treated as a disconnected network") })
        await fulfillment(of: [checked], timeout: 1)
        XCTAssertEqual(count, 3)
    }
    func testStoppedProbeAndOldFailureCannotCloseNewConnection() async {
        let first = expectation(description: "First probe sent")
        let second = expectation(description: "Second connection remains healthy")
        let heartbeat = ConnectionHeartbeat(interval: 1_000_000, timeout: 200_000_000)
        var old: (@Sendable (Bool) -> Void)?
        heartbeat.start(probe: { old = $0; first.fulfill() }, onFailure: { XCTFail("Cancelled connection failed") })
        await fulfillment(of: [first], timeout: 1)
        heartbeat.stop()
        heartbeat.start(probe: { reply in reply(true); heartbeat.stop(); second.fulfill() },
                        onFailure: { XCTFail("Old callback affected new connection") })
        old?(false)
        await fulfillment(of: [second], timeout: 1)
    }
    func testImmediateProbeErrorFailsOnceAndStopsFutureProbes() async {
        let failed = expectation(description: "Ping error")
        let heartbeat = ConnectionHeartbeat(interval: 1_000_000, timeout: 20_000_000)
        var failures = 0
        heartbeat.start(probe: { reply in reply(false); reply(false) },
                        onFailure: { failures += 1; failed.fulfill() })
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(failures, 1)
        heartbeat.stop()
    }
    func testDoubaoHeartbeatFailureClosesControllerCaptureAndAllowsRedial() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, keys = TestCredentials()
        try keys.save("synthetic")
        let transport = FakeRealtimeDriver(), speech = FakeSpeech()
        let realtime = RealtimeConversation(defaults: defaults, credentials: keys, driver: transport)
        realtime.enabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memory.json"), speech: speech, defaults: defaults, realtime: realtime)
        let failed = expectation(description: "Real Doubao driver reports timeout")
        let heartbeat = ConnectionHeartbeat(interval: 1_000_000, timeout: 20_000_000)
        let wire = DoubaoRealtime(ping: { _ in }, heartbeat: heartbeat)
        defer { wire.stop(); controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.startCall(); transport.onReady?()
        wire.onFailure = { message in transport.onFailure?(message); failed.fulfill() }
        var bytes = try DoubaoPacket.encode(event: 150, sessionID: "", payload: Data("{}".utf8)); bytes[1] = 0x94
        try wire.receive(DoubaoPacket.decode(bytes))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertFalse(controller.callInProgress); XCTAssertFalse(controller.microphoneRunning)
        XCTAssertTrue(controller.errorText?.contains("连接") == true)
        controller.startCall(); transport.onReady?()
        XCTAssertEqual(transport.starts, 2); XCTAssertTrue(controller.callInProgress)
    }
}
