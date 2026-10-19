import XCTest
@testable import CompanionCore

final class RealtimeClientTests: XCTestCase {
    func testCallUsesFixedOriginMultipartAndNeverPutsKeyInPayload() async throws {
        let client = RealtimeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/realtime/calls")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            let body = String(data: request.httpBody!, encoding: .utf8)!
            XCTAssertFalse(body.contains("test-secret"))
            XCTAssertTrue(body.contains("name=\"sdp\""))
            XCTAssertTrue(body.contains("v=0"))
            XCTAssertTrue(body.contains("semantic_vad"))
            XCTAssertFalse(body.contains("idle_timeout_ms"))
            return (Data("v=0\r\nanswer".utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        let answer = try await client.createCall(offer: "v=0\r\noffer", key: "test-secret", configuration: .init(name: "小禾", model: "gpt-realtime-2.1", voice: "marin", memories: [], memoryEnabled: true))
        XCTAssertTrue(answer.hasPrefix("v=0"))
    }
    func testProviderErrorsAreSanitized() async throws {
        let client = RealtimeClient { request in
            (Data("private text and secret".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await client.createCall(offer: "v=0", key: "test-secret", configuration: .init(name: "小禾"))
            XCTFail("must reject")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private text"))
            XCTAssertTrue(error.localizedDescription.contains("Key"))
        }
    }
    func testMemoryDisabledExcludesPrivateContextAndTools() throws {
        let config = RealtimeConfiguration(name: "小禾", memories: [.init(key: "music", content: "secret preference", kind: .preference)], memoryEnabled: false)
        let json = String(data: try JSONSerialization.data(withJSONObject: config.session), encoding: .utf8)!
        XCTAssertFalse(json.contains("secret preference"))
        XCTAssertTrue((config.session["tools"] as? [Any])?.isEmpty == true)
        XCTAssertEqual(config.session["output_modalities"] as? [String], ["audio"])
    }
}
