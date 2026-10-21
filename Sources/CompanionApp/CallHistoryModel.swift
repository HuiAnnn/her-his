import Foundation
import Combine
import CompanionCore

@MainActor final class CallHistoryModel: ObservableObject {
    @Published private(set) var calls: [CallRecord] = []
    @Published private(set) var enabled: Bool
    @Published private(set) var error: String?
    @Published private(set) var continuityEnabled: Bool
    var onRecallInvalidated: (() -> Void)?
    private var recallAfter: Date
    private let defaults: UserDefaults
    private var store: CallHistoryStore?

    init(fileURL: URL, defaults: UserDefaults) {
        self.defaults = defaults
        continuityEnabled = defaults.object(forKey: "continuityEnabled") as? Bool ?? true
        // Earlier versions did not track which historical facts were deleted.
        // Start with new calls on upgrade instead of resurrecting those facts.
        recallAfter = defaults.object(forKey: "continuityAfter") as? Date ?? Date()
        defaults.set(recallAfter, forKey: "continuityAfter")
        enabled = defaults.object(forKey: "callHistoryEnabled") as? Bool ?? true
        do { store = try CallHistoryStore(fileURL: fileURL, ownerID: NSUserName()); calls = store?.calls ?? [] }
        catch { self.error = error.localizedDescription }
    }
    func setEnabled(_ value: Bool) {
        if !value { onRecallInvalidated?(); finish() }
        enabled = value; defaults.set(value, forKey: "callHistoryEnabled")
    }
    func setContinuityEnabled(_ value: Bool) {
        if !value { onRecallInvalidated?() }
        continuityEnabled = value; defaults.set(value, forKey: "continuityEnabled")
    }
    func continuity(companion: String) -> String {
        guard enabled, continuityEnabled, error == nil else { return "" }
        return ConversationContinuity.prompt(calls: calls, companion: companion, after: recallAfter)
    }
    /// Conservative invalidation: edited/deleted facts cannot return via an older call.
    func excludePastFromRecall() {
        recallAfter = Date(); defaults.set(recallAfter, forKey: "continuityAfter")
        onRecallInvalidated?()
    }
    func begin(companion: String, provider: String) {
        perform { try $0.begin(companion: companion, provider: provider, enabled: enabled) }
    }
    func append(role: String, text: String) {
        guard enabled else { return }
        perform { try $0.append(role: role, text: text) }
    }
    func finish() { perform { try $0.finish() } }
    func delete(_ id: UUID) { perform(clearError: true) { try $0.delete(id: id) }; excludePastFromRecall() }
    func clear() { perform(clearError: true) { try $0.clear() }; excludePastFromRecall() }
    private func perform(clearError: Bool = false, _ action: (CallHistoryStore) throws -> Void) {
        guard let store else { return }
        do { try action(store); calls = store.calls; if clearError { error = nil } }
        catch { self.error = "历史记录保存或操作未完成：\(error.localizedDescription)" }
    }
}
