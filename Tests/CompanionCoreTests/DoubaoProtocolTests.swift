import XCTest
@testable import CompanionCore

final class DoubaoProtocolTests: XCTestCase {
    func testPatientSilenceWindow() throws {
        let session = try DoubaoPacket.session(.init(name: "Companion", model: "1.2.1.1", voice: "zh_female_vv_jupiter_bigtts"))
        let extra = (session["asr"] as? [String: Any])?["extra"] as? [String: Any]
        XCTAssertEqual(extra?["end_smooth_window_ms"] as? Int, 3000)
        XCTAssertEqual(extra?["enable_custom_vad"] as? Bool, true)
    }
    func testOfficialStartConnectionFixture() throws {
        XCTAssertEqual(try DoubaoPacket.encode(event: 1, payload: Data("{}".utf8)), Data([17,20,16,0,0,0,0,1,0,0,0,2,123,125]))
    }
    func testSessionAudioAndServerConnectionDecode() throws {
        var audio = try DoubaoPacket.encode(event: 352, sessionID: "s", payload: Data([0,128,255,127]), audio: true)
        audio[1] = 0xB4
        let packet = try DoubaoPacket.decode(audio)
        XCTAssertEqual(packet.event, 352); XCTAssertEqual(packet.sessionID, "s")
        XCTAssertEqual(packet.payload, Data([0,128,255,127]))
        let connection = Data([17,148,16,0,0,0,0,50,0,0,0,1,99,0,0,0,2,123,125])
        XCTAssertEqual(try DoubaoPacket.decode(connection).event, 50)
        for length in 0..<audio.count { XCTAssertThrowsError(try DoubaoPacket.decode(audio.prefix(length))) }
    }
    func testCredentialsAndConfiguration() throws {
        let credential = DoubaoCredentials(appID: "123", accessToken: "unit-test")
        let request = try credential.request()
        XCTAssertEqual(request.url?.host, "openspeech.bytedance.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Access-Key"), "unit-test")
        XCTAssertNil(request.httpBody)
        XCTAssertThrowsError(try DoubaoCredentials(appID: "123\nInjected", accessToken: "token").request())
        let config = RealtimeConfiguration(name: "小禾", model: "1.2.1.1", voice: "zh_female_vv_jupiter_bigtts", memoryEnabled: false)
        let session = try DoubaoPacket.session(config)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: session), as: UTF8.self)
        XCTAssertTrue(json.contains("pcm_s16le")); XCTAssertFalse(json.contains("update_memory"))
    }
}
