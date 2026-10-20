import Foundation
import Darwin

public struct CallRecord: Identifiable, Codable, Equatable, Sendable {
    public struct Line: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public let role: String
        public let text: String
        public let time: Date
    }
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public let companion: String
    public let provider: String
    public var lines: [Line]
}

@MainActor public final class CallHistoryStore {
    private struct Envelope: Codable { let ownerID: String; let calls: [CallRecord] }
    public private(set) var calls: [CallRecord] = []
    private let fileURL: URL, ownerID: String
    private let byteLimit: Int
    private var current: CallRecord?
    public init(fileURL: URL, ownerID: String, byteLimit: Int = 32_000_000) throws {
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CallHistoryError.unreadable }
        self.fileURL = fileURL; self.ownerID = ownerID; self.byteLimit = byteLimit
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= byteLimit else { throw CallHistoryError.full }
            let data = try Data(contentsOf: fileURL)
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.ownerID == ownerID,
                  Set(envelope.calls.map(\.id)).count == envelope.calls.count,
                  envelope.calls.allSatisfy({ $0.lines.allSatisfy { ["user", "assistant"].contains($0.role) } })
            else { throw CallHistoryError.unreadable }
            calls = envelope.calls.sorted { $0.startedAt > $1.startedAt }
        }
    }
    public func begin(companion: String, provider: String, enabled: Bool, now: Date = Date()) throws {
        try finish(now: now)
        if enabled { current = .init(id: UUID(), startedAt: now, companion: companion, provider: provider, lines: []) }
    }
    public func append(role: String, text: String, now: Date = Date()) throws {
        guard var call = current, ["user", "assistant"].contains(role),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let safe = MemoryPolicy.preventMemoryStorage(in: text) ? "[隐私内容已省略]" : text
        call.lines.append(.init(id: UUID(), role: role, text: safe, time: now))
        do {
            // Leave room for the finish timestamp; after a failed append this call
            // stays a saved fragment rather than silently skipping a missing turn.
            try persist([call] + calls.filter { $0.id != call.id }, reservedBytes: 128)
        } catch { current = nil; throw error }
        current = call
    }
    public func finish(now: Date = Date()) throws {
        guard var call = current else { return }
        current = nil // Ending must never let late callbacks append to the old call.
        guard !call.lines.isEmpty else { return }
        call.endedAt = now
        try persist([call] + calls.filter { $0.id != call.id })
    }
    public func delete(id: UUID) throws {
        try persist(calls.filter { $0.id != id })
        if current?.id == id { current = nil }
    }
    public func clear() throws { try persist([]); current = nil }
    private func persist(_ next: [CallRecord], reservedBytes: Int = 0) throws {
        let data = try JSONEncoder().encode(Envelope(ownerID: ownerID, calls: next))
        guard data.count <= max(0, byteLimit - reservedBytes) else { throw CallHistoryError.full }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        calls = next.sorted { $0.startedAt > $1.startedAt }
    }
}

public enum CallHistoryError: LocalizedError {
    case unreadable, full
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "通话历史无法读取或不属于当前用户，原文件已保留。"
        case .full: return "通话历史已达到容量限制，未覆盖已有内容。请删除不再需要的历史后再试。"
        }
    }
}
