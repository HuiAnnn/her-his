import XCTest
@testable import CompanionCore

final class MemoryStoreTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, MemoryStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("memories.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (url, try MemoryStore(fileURL: url, ownerID: "owner-a"))
    }
    private var tea: MemoryCandidate {
        MemoryCandidate(key: "饮品偏好", content: "用户喜欢喝茶", kind: .preference, evidence: "我喜欢喝茶")
    }
    @MainActor func testPersistsMemoryWithoutRawEvidenceAndUpsertsTopic() throws {
        let (url, store) = try fixture()
        XCTAssertTrue(try store.apply(candidates: [tea], source: "今天我喜欢喝茶，私密原句不留存", expectedRevision: 0, enabled: true))
        XCTAssertEqual(store.memories.count, 1)
        let id = try XCTUnwrap(store.memories.first?.id)
        XCTAssertTrue(try store.apply(candidates: [.init(key: " 饮品偏好 ", content: "用户喜欢绿茶", kind: .preference, evidence: "喜欢绿茶")], source: "现在喜欢绿茶", expectedRevision: store.revision, enabled: true))
        let reloaded = try MemoryStore(fileURL: url, ownerID: "owner-a")
        XCTAssertEqual(reloaded.memories.count, 1)
        XCTAssertEqual(reloaded.memories.first?.id, id)
        XCTAssertEqual(reloaded.memories.first?.content, "用户喜欢绿茶")
        let disk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(disk.contains("私密原句不留存"))
        XCTAssertFalse(disk.contains("evidence"))
    }
    @MainActor func testDeletionRejectsInFlightAndFutureBlockedKeyAcrossReload() throws {
        let (url, store) = try fixture()
        _ = try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: 0, enabled: true)
        let stale = store.revision
        try store.delete(id: XCTUnwrap(store.memories.first?.id))
        XCTAssertFalse(try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: stale, enabled: true))
        let reloaded = try MemoryStore(fileURL: url, ownerID: "owner-a")
        XCTAssertFalse(try reloaded.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: reloaded.revision, enabled: true))
        XCTAssertTrue(reloaded.memories.isEmpty)
        let disk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(disk.contains("喝茶"))
        XCTAssertFalse(disk.contains("饮品偏好"))
    }
    @MainActor func testClearAndDisableInvalidatePendingWrites() throws {
        let (url, store) = try fixture()
        _ = try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: 0, enabled: true)
        let old = store.revision
        try store.clear()
        XCTAssertFalse(try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: old, enabled: true))
        XCTAssertTrue(try MemoryStore(fileURL: url, ownerID: "owner-a").memories.isEmpty)
        let current = store.revision
        store.invalidatePending()
        XCTAssertFalse(try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: current, enabled: true))
        XCTAssertFalse(try store.apply(candidates: [.init(key: "new", content: "用户喜欢花", kind: .preference, evidence: "喜欢花")], source: "喜欢花", expectedRevision: store.revision, enabled: false))
    }
    @MainActor func testOwnerMismatchAndCorruptionAreErrorsWithoutOverwriting() throws {
        let (url, store) = try fixture()
        _ = try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: 0, enabled: true)
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try MemoryStore(fileURL: url, ownerID: "owner-b"))
        XCTAssertEqual(try Data(contentsOf: url), saved)
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try MemoryStore(fileURL: url, ownerID: "owner-a"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
    @MainActor func testRejectsUnsupportedEvidenceAndForbiddenSources() throws {
        let (_, store) = try fixture()
        let cases = ["我喜欢咖啡", "我喜欢喝茶，但这件事别记", "假如我喜欢喝茶", "朋友说我喜欢喝茶", "我喜欢喝茶。我的密码是 abc", "我喜欢喝茶，不要保存", "我喜欢喝茶，验证码123456", "I like tea, don't remember this"]
        for source in cases {
            XCTAssertFalse(try store.apply(candidates: [tea], source: source, expectedRevision: store.revision, enabled: true), source)
        }
        XCTAssertFalse(try store.apply(candidates: [.init(key: "key", content: "密码：secret", kind: .preference, evidence: "喜欢")], source: "我喜欢花", expectedRevision: store.revision, enabled: true))
        XCTAssertTrue(store.memories.isEmpty)
    }
    @MainActor func testEditIsPersistentInvalidatesPendingAndRejectsMissingID() throws {
        let (url, store) = try fixture()
        _ = try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: 0, enabled: true)
        let id = try XCTUnwrap(store.memories.first?.id)
        let old = store.revision
        try store.edit(id: id, content: "用户现在喜欢咖啡")
        XCTAssertGreaterThan(store.revision, old)
        XCTAssertEqual(try MemoryStore(fileURL: url, ownerID: "owner-a").memories.first?.content, "用户现在喜欢咖啡")
        XCTAssertThrowsError(try store.edit(id: UUID(), content: "anything"))
        XCTAssertThrowsError(try store.delete(id: UUID()))
        XCTAssertThrowsError(try store.edit(id: id, content: "  "))
    }
    @MainActor func testFailedWriteDoesNotClaimInMemorySuccess() throws {
        let (url, store) = try fixture()
        _ = try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: 0, enabled: true)
        let snapshot = store.memories
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.delete(id: XCTUnwrap(snapshot.first?.id)))
        XCTAssertEqual(store.memories, snapshot)
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(store.memories, snapshot)
    }
    @MainActor func testExplicitRememberAgainCanRestoreOnlyWithFreshEvidence() throws {
        let (url, store) = try fixture()
        _ = try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: 0, enabled: true)
        try store.delete(id: XCTUnwrap(store.memories.first?.id))
        XCTAssertFalse(try store.apply(candidates: [tea], source: "请重新记住", expectedRevision: store.revision, enabled: true))
        XCTAssertTrue(try store.apply(candidates: [tea], source: "请重新记住，我喜欢喝茶", expectedRevision: store.revision, enabled: true))
        XCTAssertEqual(try MemoryStore(fileURL: url, ownerID: "owner-a").memories.count, 1)
    }
    @MainActor func testFilePermissionsRestrictPersistedMemoryToOwner() throws {
        let (url, store) = try fixture()
        _ = try store.apply(candidates: [tea], source: "我喜欢喝茶", expectedRevision: 0, enabled: true)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
    }
    func testIntentGuardsAreConservative() {
        XCTAssertTrue(MemoryPolicy.hasForgetIntent(in: "请忘掉我的饮品偏好"))
        XCTAssertFalse(MemoryPolicy.hasForgetIntent(in: "我忘记带伞了"))
        XCTAssertTrue(MemoryPolicy.preventMemoryStorage(in: "别记住这件事"))
        XCTAssertTrue(MemoryPolicy.preventMemoryStorage(in: "密码 123456"))
        XCTAssertFalse(MemoryPolicy.preventMemoryStorage(in: "我平时喜欢喝茶"))
    }
}
