import XCTest
@testable import CompanionCore

final class ElevenLabsTests: XCTestCase {
    func testSynthesisSendsOnlyReplyToFixedHTTPSHost() async throws {
        let client = ElevenLabsClient { request in
            XCTAssertEqual(request.url?.host, "api.elevenlabs.io")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.path, "/v1/text-to-speech/voice123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(Set(body.keys), Set(["text", "model_id"]))
            XCTAssertEqual(body["text"] as? String, "我在，你慢慢说。")
            XCTAssertEqual(body["model_id"] as? String, "eleven_v3")
            return (Data([1, 2, 3]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!)
        }
        let audio = try await client.synthesize("我在，你慢慢说。", key: "test-key", voiceID: "voice123", modelID: "eleven_v3")
        XCTAssertEqual(audio, Data([1, 2, 3]))
    }

    func testAuthenticationErrorNeverIncludesServerEchoOrKey() async throws {
        let client = ElevenLabsClient { request in
            (Data("secret echoed server text".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await client.synthesize("test", key: "secret", voiceID: "voice123", modelID: "eleven_v3")
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? CloudVoiceError, .authentication)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testMissingKeyOrUnsafeVoiceIDCannotMakeNetworkRequest() async {
        let client = ElevenLabsClient { _ in XCTFail("Must validate before networking"); throw URLError(.badURL) }
        for (key, voice) in [("", "valid"), ("key", "../other?leak=1")] {
            do { _ = try await client.synthesize("hello", key: key, voiceID: voice, modelID: "eleven_v3"); XCTFail("Expected validation error") }
            catch { XCTAssertTrue(error is CloudVoiceError) }
        }
    }

    func testVoicesPaginateAndChineseModelsExcludeOtherCapabilities() async throws {
        let client = ElevenLabsClient { request in
            let json: String
            if request.url!.path == "/v1/models" {
                json = #"[{"model_id":"chinese","name":"中文模型","can_do_text_to_speech":true,"languages":[{"language_id":"zh","name":"Chinese"}]},{"model_id":"english","can_do_text_to_speech":true,"languages":[{"language_id":"en"}]},{"model_id":"converter","can_do_text_to_speech":false,"languages":[{"language_id":"zh"}]}]"#
            } else if request.url!.query!.contains("next_page_token=second") {
                json = #"{"voices":[{"voice_id":"two","name":"Two"}],"has_more":false,"next_page_token":null}"#
            } else {
                json = #"{"voices":[{"voice_id":"one","name":"One","labels":{"language":"zh"}}],"has_more":true,"next_page_token":"second"}"#
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let voices = try await client.voices(key: "test")
        XCTAssertEqual(voices.map(\.id), ["one", "two"])
        let models = try await client.models(key: "test")
        XCTAssertEqual(models.map(\.id), ["chinese"])
    }

    func testSuccessWithoutAudioIsRejected() async throws {
        let client = ElevenLabsClient { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        do { _ = try await client.synthesize("hello", key: "test", voiceID: "one", modelID: "model"); XCTFail("Expected invalid audio") }
        catch { XCTAssertEqual(error as? CloudVoiceError, .invalidResponse) }
    }
}
