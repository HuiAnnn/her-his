import Foundation
import CompanionCore

/// One update on the wire at a time: Doubao acknowledgments have no request ID.
@MainActor final class LiveMemorySync {
    var onSend: ((RealtimeConfiguration, Int) -> Void)?
    var onStatus: ((String) -> Void)?
    var onSettled: (() -> Void)?
    var onRejected: (() -> Void)?
    private struct Update { let revision: Int; let key: String; let config: RealtimeConfiguration }
    private var configuration: RealtimeConfiguration?
    private var inFlight: Update?
    private var desired: (key: String, config: RealtimeConfiguration)?
    private var appliedKey = "", query = ""
    private var recentKeys: [String] = []
    private var issuedEvents: Set<String> = []
    private var sequence = 0, epoch = 0
    private var ready = false, blocked = false
    private var deadline: Task<Void, Never>?
    private let timeout: UInt64
    init(timeout: UInt64 = 8_000_000_000) { self.timeout = timeout }
    var hasFailed: Bool { blocked }
    var isWaiting: Bool { inFlight != nil || desired != nil }

    func start(_ config: RealtimeConfiguration) {
        stop(); configuration = config
        appliedKey = MemoryContext.json(config.memories, enabled: config.memoryEnabled)
    }
    func activate() { ready = true; refresh() }
    func stop() {
        epoch += 1; deadline?.cancel(); deadline = nil
        inFlight = nil; desired = nil; configuration = nil; issuedEvents.removeAll()
        recentKeys = []; query = ""; appliedKey = ""; ready = false; blocked = false
        onStatus?("")
    }
    func update(_ memories: [CompanionMemory]) {
        guard var config = configuration, config.memoryEnabled else { return }
        let old = Dictionary(config.memories.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
        let changed = memories.filter { old[$0.key] != $0 }.sorted { $0.updatedAt > $1.updatedAt }.map(\.key)
        recentKeys = Array((changed + recentKeys.filter { !changed.contains($0) }).prefix(8))
        config.memories = memories; configuration = config; refresh()
    }
    func retrieve(_ text: String) {
        guard !MemoryPolicy.preventMemoryStorage(in: text) else { return }
        query = String(text.prefix(4000)); refresh()
    }
    private func refresh() {
        guard ready, !blocked, var config = configuration, config.memoryEnabled else { return }
        config.memories = MemoryContext.select(config.memories, query: query, recentKeys: recentKeys)
        let key = MemoryContext.json(config.memories)
        if let inFlight {
            desired = key == inFlight.key ? nil : (key, config)
            return
        }
        guard key != appliedKey else { desired = nil; return }
        sequence += 1
        let update = Update(revision: sequence, key: key, config: config)
        inFlight = update; desired = nil
        onStatus?("正在同步当前对话记忆…")
        let token = epoch
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: self?.timeout ?? 0) } catch { return }
            guard let self, self.epoch == token else { return }
            self.reject(update.revision)
        }
        issuedEvents.insert("memory_context_\(update.revision)")
        onSend?(config, update.revision)
    }
    func acknowledge(_ revision: Int) {
        guard !blocked, let update = inFlight, update.revision == revision else { return }
        let token = epoch
        deadline?.cancel(); deadline = nil; inFlight = nil
        appliedKey = update.key
        // Recalculate from the latest bank/query, never from the acknowledged older snapshot.
        desired = nil; refresh()
        if epoch == token && ready && configuration != nil && !isWaiting && !blocked {
            onStatus?("记忆已同步当前对话"); onSettled?()
        }
    }
    func acknowledgeInstructions(_ instructions: String) {
        guard let update = inFlight, instructions == update.config.session["instructions"] as? String else { return }
        acknowledge(update.revision)
    }
    func reject(_ revision: Int) {
        guard inFlight?.revision == revision else { return }
        deadline?.cancel(); deadline = nil
        // No retry on this connection: a late uncorrelated ACK must not confirm a newer update.
        inFlight = nil; desired = nil; blocked = true
        onStatus?("当前对话的记忆同步未确认；声音可继续，新记忆仍保存在本机")
        onRejected?()
    }
    func rejectEvent(_ eventID: String) -> Bool {
        guard issuedEvents.contains(eventID) else { return false }
        if let update = inFlight, eventID == "memory_context_\(update.revision)" { reject(update.revision) }
        return true
    }
}
