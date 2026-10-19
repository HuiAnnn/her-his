import Foundation
import CryptoKit
import Darwin
public enum MemoryKind: String, Codable, Sendable { case preference, event, boundary }
public struct CompanionMemory: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var key: String
    public var content: String
    public var kind: MemoryKind
    public var updatedAt: Date
    public init(id: UUID = UUID(), key: String, content: String, kind: MemoryKind, updatedAt: Date = Date()) {
        self.id = id; self.key = key; self.content = content; self.kind = kind; self.updatedAt = updatedAt
    }
}
public struct MemoryCandidate: Codable, Sendable {
    public var key: String
    public var content: String
    public var kind: MemoryKind
    public var evidence: String
    public init(key: String, content: String, kind: MemoryKind, evidence: String) {
        self.key = key; self.content = content; self.kind = kind; self.evidence = evidence
    }
}
public enum MemoryPolicy {
    private static func contains(_ text: String, _ phrases: [String]) -> Bool {
        let normalized = text.lowercased()
        return phrases.contains { normalized.contains($0) }
    }
    public static func hasForgetIntent(in text: String) -> Bool {
        contains(text, ["忘掉", "忘了这", "忘记这", "忘记我", "删除记忆", "清除记忆", "清空记忆", "删掉", "别记", "不要记", "不要保存", "不保存", "forget this", "forget my", "delete my", "don't remember", "do not remember", "don't save", "do not save"])
    }
    public static func preventMemoryStorage(in text: String) -> Bool {
        hasForgetIntent(in: text) || containsCredentials(text) || contains(text, ["这件事别存", "不要存", "别保存", "不许记", "不想被记", "别记录"])
    }
    public static func isStorageNarration(_ text: String) -> Bool {
        // Full evidence may contain a real fact followed by a save instruction.
        // Reject only when every clause is narration, rather than discarding the fact.
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。.!！?？；;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return !clauses.isEmpty && clauses.allSatisfy { clause in
            (contains(clause, ["慢慢记得", "记忆页", "记忆列表"]) && contains(clause, ["保存", "存到", "记下来", "记住"]))
                || ["请记住我的生日", "记住我的生日", "生日已保存", "生日会被保存"].contains(clause)
        }
    }
    // Keep question punctuation while inspecting the original clause, so a model
    // cannot turn “我喜欢什么？” into a fact by quoting only “我喜欢”.
    public static func hasDeclarativeEvidence(_ evidence: String, in source: String) -> Bool {
        let cleanEvidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEvidence.isEmpty, source.contains(evidence) else { return false }
        var clauses: [String] = [], current = ""
        for character in source {
            current.append(character)
            if "，,。.!！?？；;\n".contains(character) { clauses.append(current); current = "" }
        }
        if !current.isEmpty { clauses.append(current) }
        return clauses.enumerated().contains { index, clause in
            let text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["还是", "或是", "或者是"].contains(where: text.hasPrefix) { return false }
            // An alternative continues the preceding question even when ASR omits “？”.
            if index + 1 < clauses.count, let last = text.last, "，,".contains(last) {
                let next = clauses[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if ["还是", "或是", "或者是"].contains(where: next.hasPrefix) { return false }
            }
            let interrogative = text.replacingOccurrences(of: "不怎么", with: "很少")
                .replacingOccurrences(of: "没怎么", with: "很少")
                .replacingOccurrences(of: "什么都", with: "全部")
                .replacingOccurrences(of: "什么也", with: "任何东西也")
            let question = text.contains("?") || text.contains("？")
                || ["什么", "怎么", "为何", "为什么", "是否", "是不是", "哪天", "哪一天", "多少", "几号", "吗", "能不能", "可不可以"].contains(where: interrogative.contains)
                || ["what ", "when ", "why ", "how ", "do you ", "can you ", "could you ", "is my "].contains(where: text.lowercased().hasPrefix)
            let body = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            return !question && !body.isEmpty && !isStorageNarration(body)
                && (text.contains(cleanEvidence) || cleanEvidence.contains(body))
        }
    }
    static func requestsRememberAgain(_ text: String) -> Bool {
        contains(text, ["重新记住", "重新保存", "remember this again", "remember my preference again"])
    }
    static func containsCredentials(_ text: String) -> Bool {
        contains(text, ["密码", "口令", "验证码", "密钥", "password", "passcode", "api_key", "api key", "api-key", "secret key", "access token", "bearer ", "sk-", "-----begin"])
    }
    static func isUncertainSource(_ text: String) -> Bool {
        contains(text, ["不确定", "假如", "假设", "如果我", "朋友说", "他说", "她说", "引用", "听不清", "没听清", "也许我", "可能我", "suppose", "hypothetical", "my friend said", "he said", "she said"])
            || text.contains("“") || text.contains("「") || text.contains("\"")
    }
}

public enum MemoryStoreError: LocalizedError {
    case invalidOwner, ownerMismatch, corruptFile, invalidContent, missingMemory, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidOwner: return "无法确认记忆所属用户。"
        case .ownerMismatch: return "记忆属于另一位用户，未读取或修改。"
        case .corruptFile: return "记忆文件无法读取，原文件已保留。"
        case .invalidContent: return "记忆内容为空、过长或包含不应保存的信息。"
        case .missingMemory: return "没有找到这条记忆。"
        case .tooLarge: return "记忆文件过大，未读取。"
        }
    }
}

private struct MemoryEnvelope: Codable {
    var ownerID: String
    var memories: [CompanionMemory]
    var blockedTopicHashes: Set<String>
}

@MainActor public final class MemoryStore {
    public private(set) var memories: [CompanionMemory] = []
    public private(set) var revision = 0
    private let fileURL: URL
    private let ownerID: String
    private var blockedTopicHashes: Set<String> = []

    public init(fileURL: URL, ownerID: String) throws {
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemoryStoreError.invalidOwner }
        self.fileURL = fileURL; self.ownerID = ownerID
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw MemoryStoreError.tooLarge }
            let data = try Data(contentsOf: fileURL)
            guard let envelope = try? JSONDecoder().decode(MemoryEnvelope.self, from: data),
                  envelope.memories.allSatisfy({ Self.validKey($0.key) && Self.validContent($0.content) }),
                  Set(envelope.memories.map(\.id)).count == envelope.memories.count else { throw MemoryStoreError.corruptFile }
            guard envelope.ownerID == ownerID else { throw MemoryStoreError.ownerMismatch }
            memories = envelope.memories; blockedTopicHashes = envelope.blockedTopicHashes
        }
    }
    public func invalidatePending() { revision += 1 }

    /// Returns true only when new memory state has been durably written.
    @discardableResult public func apply(candidates: [MemoryCandidate], source: String, expectedRevision: Int, enabled: Bool) throws -> Bool {
        guard enabled, expectedRevision == revision, !MemoryPolicy.preventMemoryStorage(in: source),
              !MemoryPolicy.isUncertainSource(source) else { return false }
        var next = memories
        var blocked = blockedTopicHashes
        let rememberAgain = MemoryPolicy.requestsRememberAgain(source)
        for candidate in candidates.prefix(8) {
            let key = Self.canonical(candidate.key)
            let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validKey(key), Self.validContent(content), !MemoryPolicy.isStorageNarration(content),
                  !MemoryPolicy.isStorageNarration(candidate.evidence),
                  MemoryPolicy.hasDeclarativeEvidence(candidate.evidence, in: source),
                  !candidate.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.contains(candidate.evidence), candidate.evidence.count <= 500,
                  !MemoryPolicy.preventMemoryStorage(in: key) else { continue }
            let keyHash = Self.hash(key), contentHash = Self.hash(content)
            if blocked.contains(keyHash) || blocked.contains(contentHash) {
                guard rememberAgain else { continue }
                blocked.remove(keyHash); blocked.remove(contentHash)
            }
            if let index = next.firstIndex(where: { Self.canonical($0.key) == key }) {
                if next[index].content == content && next[index].kind == candidate.kind { continue }
                next[index].content = content; next[index].kind = candidate.kind; next[index].updatedAt = Date()
            } else if next.count < 500 {
                next.append(CompanionMemory(key: key, content: content, kind: candidate.kind))
            }
        }
        guard next != memories else { return false }
        try persist(next, blocked: blocked)
        memories = next; blockedTopicHashes = blocked; revision += 1
        return true
    }

    public func delete(id: UUID) throws {
        guard let memory = memories.first(where: { $0.id == id }) else { throw MemoryStoreError.missingMemory }
        invalidatePending()
        var blocked = blockedTopicHashes
        blocked.insert(Self.hash(memory.key)); blocked.insert(Self.hash(memory.content))
        let next = memories.filter { $0.id != id }
        try persist(next, blocked: blocked)
        memories = next; blockedTopicHashes = blocked
    }
    public func clear() throws {
        invalidatePending()
        var blocked = blockedTopicHashes
        for memory in memories { blocked.insert(Self.hash(memory.key)); blocked.insert(Self.hash(memory.content)) }
        try persist([], blocked: blocked)
        memories = []; blockedTopicHashes = blocked
    }
    public func edit(id: UUID, content: String) throws {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { throw MemoryStoreError.missingMemory }
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validContent(clean) else { throw MemoryStoreError.invalidContent }
        invalidatePending()
        var next = memories
        next[index].content = clean; next[index].updatedAt = Date()
        try persist(next, blocked: blockedTopicHashes)
        memories = next
    }

    private static func canonical(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(canonical(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func validKey(_ text: String) -> Bool { (1...80).contains(text.count) }
    private static func validContent(_ text: String) -> Bool {
        (1...240).contains(text.count) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !MemoryPolicy.preventMemoryStorage(in: text)
    }
    private func persist(_ next: [CompanionMemory], blocked: Set<String>) throws {
        let data = try JSONEncoder().encode(MemoryEnvelope(ownerID: ownerID, memories: next, blockedTopicHashes: blocked))
        guard data.count <= 1_048_576 else { throw MemoryStoreError.tooLarge }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".memory-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
