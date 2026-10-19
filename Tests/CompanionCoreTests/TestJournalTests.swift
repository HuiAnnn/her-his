import XCTest
@testable import CompanionCore

final class TestJournalTests: XCTestCase {
    func testOptInPersistenceRedactionRetentionAndClear() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test-records.json")
        let journal = TestJournal(fileURL: file, limit: 3)
        try journal.append(kind: "user", text: "off", enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try journal.append(kind: "user", text: "expired", enabled: true, now: Date().addingTimeInterval(-8 * 86400))
        try journal.append(kind: "user", text: "我的生日是6月18日", enabled: true)
        try journal.append(kind: "user", text: "密码是 example", enabled: true)
        try journal.append(kind: "memory", text: "已保存 birthday", enabled: true)
        let entries = try JSONDecoder().decode([TestJournal.Entry].self, from: Data(contentsOf: file))
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(entries.contains { $0.text.contains("expired") || $0.text.contains("example") })
        XCTAssertEqual(entries.first?.text, "我的生日是6月18日")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let reopened = TestJournal(fileURL: file, limit: 3)
        try reopened.append(kind: "assistant", text: "我记得", enabled: true)
        XCTAssertEqual(try JSONDecoder().decode([TestJournal.Entry].self, from: Data(contentsOf: file)).count, 3)
        try reopened.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
