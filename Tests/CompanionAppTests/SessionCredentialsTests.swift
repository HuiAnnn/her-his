import XCTest
@testable import CompanionApp

@MainActor final class SessionCredentialsTests: XCTestCase {
    func testRepeatedUseDoesNotReauthorizeAndInvalidationReadsAgain() throws {
        let store = CountingCredentialStore()
        let credentials = SessionCredentials(store)
        XCTAssertEqual(try credentials.read(), "synthetic-key")
        XCTAssertEqual(try credentials.read(), "synthetic-key")
        XCTAssertEqual(store.reads, 1)
        credentials.invalidate()
        XCTAssertEqual(try credentials.read(), "synthetic-key")
        XCTAssertEqual(store.reads, 2)
    }
    func testSaveAndDeleteCannotLeaveStaleCachedCredentials() throws {
        let store = CountingCredentialStore(), credentials: SessionCredentials
        credentials = SessionCredentials(store)
        _ = try credentials.read()
        try credentials.save("replacement")
        XCTAssertEqual(try credentials.read(), "replacement")
        XCTAssertEqual(store.reads, 1)
        try credentials.delete()
        XCTAssertNil(try credentials.read())
        store.value = "external-replacement"
        XCTAssertEqual(try credentials.read(), "external-replacement")
        store.fail = true
        XCTAssertThrowsError(try credentials.save("failed-save"))
        XCTAssertThrowsError(try credentials.read())
        store.fail = false
        XCTAssertEqual(try credentials.read(), "external-replacement")
        store.fail = true
        XCTAssertThrowsError(try credentials.delete())
        XCTAssertThrowsError(try credentials.read())
    }
}
@MainActor private final class CountingCredentialStore: VoiceCredentialStoring {
    var reads = 0, fail = false
    var value: String? = "synthetic-key"
    func read() throws -> String? { reads += 1; if fail { throw Failure.denied }; return value }
    func save(_ value: String) throws { if fail { throw Failure.denied }; self.value = value }
    func delete() throws { if fail { throw Failure.denied }; value = nil }
    enum Failure: Error { case denied }
}
