import Foundation

/// Local opt-in diagnostics. Call serially from the application's main actor.
public final class TestJournal {
    public struct Entry: Codable {
        public let time: Date
        public let session: UUID
        public let kind: String
        public let text: String
    }
    public let fileURL: URL
    private let session = UUID()
    private let limit: Int
    public init(fileURL: URL, limit: Int = 1000) { self.fileURL = fileURL; self.limit = max(1, limit) }
    public func append(kind: String, text: String, enabled: Bool, now: Date = Date()) throws {
        guard enabled else { return }
        var entries: [Entry] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            guard data.count < 32_000_000 else { throw MemoryStoreError.tooLarge }
            entries = try JSONDecoder().decode([Entry].self, from: data)
        }
        entries.removeAll { $0.time < now.addingTimeInterval(-7 * 86400) }
        let content = MemoryPolicy.preventMemoryStorage(in: text) ? "[隐私内容已省略]" : String(text.prefix(6000))
        entries.append(.init(time: now, session: session, kind: kind, text: content))
        entries = Array(entries.suffix(limit))
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }
}
