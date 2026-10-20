import XCTest
@testable import CompanionCore

@MainActor final class CallHistoryTests: XCTestCase {
    var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    var file: URL { directory.appendingPathComponent("call-history.json") }
    func testCallsPersistSeparatelyWithRoleAndTimeAndPrivatePermissions() throws {
        let store = try CallHistoryStore(fileURL: file, ownerID: "fixture")
        let time = Date(timeIntervalSince1970: 100)
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true, now: time)
        try store.append(role: "user", text: "今天练习画画", now: time)
        try store.append(role: "assistant", text: "画了什么呢", now: time)
        try store.finish(now: time.addingTimeInterval(20))
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true, now: time.addingTimeInterval(30))
        try store.append(role: "user", text: "又见面了")
        try store.finish()
        let reopened = try CallHistoryStore(fileURL: file, ownerID: "fixture")
        XCTAssertEqual(reopened.calls.count, 2)
        XCTAssertEqual(reopened.calls.last?.lines.map(\.role), ["user", "assistant"])
        XCTAssertEqual(reopened.calls.last?.endedAt, time.addingTimeInterval(20))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testNoEmptyOrDisabledCallsAndLateAppendAfterFinishIsIgnored() throws {
        let store = try CallHistoryStore(fileURL: file, ownerID: "fixture")
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true); try store.finish()
        XCTAssertTrue(store.calls.isEmpty)
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: false)
        try store.append(role: "user", text: "不保存的通话"); try store.finish()
        XCTAssertTrue(store.calls.isEmpty)
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true)
        try store.append(role: "user", text: "正常通话"); try store.finish()
        try store.append(role: "assistant", text: "迟到回复")
        XCTAssertEqual(store.calls.first?.lines.count, 1)
    }
    func testDeletingCurrentCallAndClearCannotResurrectIt() throws {
        let store = try CallHistoryStore(fileURL: file, ownerID: "fixture")
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true)
        try store.append(role: "user", text: "第一通")
        let id = try XCTUnwrap(store.calls.first?.id)
        try store.delete(id: id); try store.append(role: "assistant", text: "迟到内容"); try store.finish()
        XCTAssertTrue(store.calls.isEmpty)
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true)
        try store.append(role: "user", text: "第二通"); try store.clear()
        try store.append(role: "assistant", text: "也不能写回")
        XCTAssertTrue(try CallHistoryStore(fileURL: file, ownerID: "fixture").calls.isEmpty)
    }
    func testCredentialsAndNoSaveInstructionsAreRedacted() throws {
        let store = try CallHistoryStore(fileURL: file, ownerID: "fixture")
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true)
        try store.append(role: "user", text: "不要保存这段，fictional-hidden-value")
        try store.append(role: "assistant", text: "密码是 fictional-secret-value")
        let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(saved.contains("fictional-hidden-value")); XCTAssertFalse(saved.contains("fictional-secret-value"))
        XCTAssertEqual(store.calls.first?.lines.count, 2)
    }
    func testOwnerMismatchAndCorruptionPreserveOriginalFile() throws {
        let store = try CallHistoryStore(fileURL: file, ownerID: "fixture")
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true)
        try store.append(role: "user", text: "fixture text")
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try CallHistoryStore(fileURL: file, ownerID: "other"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try CallHistoryStore(fileURL: file, ownerID: "fixture"))
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }
    func testCapacityFailureKeepsLastSavedRecordAndUnfinishedCallSurvivesRestart() throws {
        let store = try CallHistoryStore(fileURL: file, ownerID: "fixture", byteLimit: 1800)
        try store.begin(companion: "Companion", provider: "Synthetic", enabled: true)
        try store.append(role: "user", text: "already saved")
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.append(role: "user", text: String(repeating: "x", count: 2000)))
        try store.append(role: "user", text: "short text must not resume this failed call")
        try store.finish()
        XCTAssertEqual(try Data(contentsOf: file), original)
        let reopened = try CallHistoryStore(fileURL: file, ownerID: "fixture")
        XCTAssertEqual(reopened.calls.first?.lines.map(\.text), ["already saved"])
        XCTAssertNil(reopened.calls.first?.endedAt)
    }
}
