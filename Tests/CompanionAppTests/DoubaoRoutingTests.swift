import XCTest
import CompanionCore
@testable import CompanionApp

@MainActor final class DoubaoRoutingTests: XCTestCase {
    func testProviderSwitchUsesSeparateCredentialsAndStopsSession() throws {
        let open = TestCredentials(), doubao = TestCredentials(), driver = FakeRealtimeDriver()
        try open.save("openai-test")
        let session = RealtimeConversation(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: open, doubaoCredentials: doubao, driver: driver, doubaoDriver: driver)
        session.provider = .doubao
        XCTAssertThrowsError(try session.requireKey())
        XCTAssertEqual(session.model, "1.2.1.1")
        session.appIDDraft = "123"; session.keyDraft = "doubao-test"; session.saveKey()
        let decoded = try JSONDecoder().decode(DoubaoCredentials.self, from: Data(session.requireKey().utf8))
        XCTAssertEqual(decoded.appID, "123")
        try session.start(configuration: .init(name: "小禾")); driver.onReady?()
        session.provider = .openAI
        XCTAssertEqual(session.state, .idle); XCTAssertEqual(try session.requireKey(), "openai-test")
        session.provider = .doubao; session.removeKey()
        XCTAssertEqual(try open.read(), "openai-test")
        XCTAssertNil(try doubao.read())
    }
}
