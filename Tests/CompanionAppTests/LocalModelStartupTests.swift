import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class LocalModelStartupTests: XCTestCase {
    func testUnavailableServerStartsOnceThenConnects() async throws {
        let client = StartupModel(failures: 2)
        let runtime = StartupRuntime()
        let models = try await LocalModelConnection.connect(client: client, runtime: runtime, retryDelay: 0)
        XCTAssertEqual(models, ["qwen3:4b"])
        XCTAssertEqual(runtime.starts, 1)
    }
    func testHealthyServerIsReusedWithoutStartingAnything() async throws {
        let runtime = StartupRuntime()
        let models = try await LocalModelConnection.connect(client: StartupModel(failures: 0), runtime: runtime, retryDelay: 0)
        XCTAssertEqual(models, ["qwen3:4b"])
        XCTAssertEqual(runtime.starts, 0)
    }
    func testNonLocalModelRejectionDoesNotStartService() async {
        let client = StartupModel(failures: 1)
        client.failure = ModelClientError.nonLocalModel
        let runtime = StartupRuntime()
        do { _ = try await LocalModelConnection.connect(client: client, runtime: runtime, retryDelay: 0); XCTFail("Should reject") }
        catch { XCTAssertTrue(error is ModelClientError) }
        XCTAssertEqual(runtime.starts, 0)
    }
    func testRetriesAreBoundedWhenServerNeverStarts() async {
        let runtime = StartupRuntime()
        let client = StartupModel(failures: 100)
        do { _ = try await LocalModelConnection.connect(client: client, runtime: runtime, retryDelay: 0, attempts: 3); XCTFail("Should time out") }
        catch { XCTAssertEqual(client.calls, 4) }
        XCTAssertEqual(runtime.starts, 1)
    }
    func testRecoveryClearsOnlyItsOwnError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = StartupModel(failures: 1)
        client.failure = ModelClientError.invalidResponse
        let controller = CompanionController(dataURL: directory.appendingPathComponent("memory.json"), speech: FakeSpeech(),
            defaults: UserDefaults(suiteName: "Startup-\(UUID().uuidString)")!, localRuntime: StartupRuntime(), clientFactory: { _ in client })
        defer { controller.shutdown() }
        await controller.checkConnection()
        XCTAssertNotNil(controller.errorText)
        await controller.checkConnection()
        XCTAssertTrue(controller.modelAvailable)
        XCTAssertNil(controller.errorText)
        controller.errorText = "麦克风权限未授予"
        await controller.checkConnection()
        XCTAssertEqual(controller.errorText, "麦克风权限未授予")
    }
}

@MainActor final class StartupRuntime: LocalModelStarting {
    var starts = 0
    func start() throws { starts += 1 }
    func stop() {}
}
@MainActor final class StartupModel: ModelServing {
    var failures: Int
    var calls = 0
    var failure: Error = URLError(.cannotConnectToHost)
    init(failures: Int) { self.failures = failures }
    func health() async throws -> [String] {
        calls += 1
        if failures > 0 { failures -= 1; throw failure }
        return ["qwen3:4b"]
    }
    func respond(messages: [ChatMessage], memories: [CompanionMemory], name: String, continuity: String) async throws -> ModelReply { ModelReply(reply: "我在。") }
}
