import Foundation
import Combine
import CompanionCore

@MainActor protocol RealtimeDriving: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onEvent: (([String: Any]) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start(key: String, configuration: RealtimeConfiguration)
    func send(_ event: [String: Any])
    func interrupt()
    func stop()
}

enum RealtimeState { case idle, connecting, listening, thinking, speaking }

@MainActor final class RealtimeConversation: ObservableObject {
    @Published var provider: RealtimeProvider { didSet {
        guard provider != oldValue else { return }
        stop(); defaults.set(provider.rawValue, forKey: "realtimeProvider")
        model = defaults.string(forKey: provider == .doubao ? "doubaoModel" : "realtimeModel") ?? provider.defaultModel
        voice = defaults.string(forKey: provider == .doubao ? "doubaoVoice" : "realtimeVoice") ?? provider.defaultVoice
        keyDraft = ""; appIDDraft = ""; message = "请保存\(provider.title)凭证后开启对话。"
    } }
    @Published var appIDDraft = ""
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "realtimeEnabled"); if enabled != oldValue { stop() } } }
    @Published var model: String { didSet { defaults.set(model, forKey: provider == .doubao ? "doubaoModel" : "realtimeModel"); if model != oldValue { stop() } } }
    @Published var voice: String { didSet { defaults.set(voice, forKey: provider == .doubao ? "doubaoVoice" : "realtimeVoice"); if voice != oldValue { stop() } } }
    @Published var keyDraft = ""
    @Published private(set) var message = "保存对应服务的凭证后，可开启直接语音对话。"
    @Published private(set) var state: RealtimeState = .idle { didSet { onState?(state) } }
    var onState: ((RealtimeState) -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var onAssistantTranscript: ((String) -> Void)?
    var onAssistantTestRecord: ((String, String?) -> Void)?
    var onMemoryUpdate: ((String, String) -> String)?
    var onFailure: ((String) -> Void)?
    var driver: any RealtimeDriving { provider == .doubao ? doubaoDriver : openAIDriver }
    let openAIDriver: any RealtimeDriving
    let doubaoDriver: any RealtimeDriving
    private let defaults: UserDefaults
    private var credentials: any VoiceCredentialStoring { provider == .doubao ? doubaoCredentials : openAICredentials }
    private let openAICredentials: any VoiceCredentialStoring
    private let doubaoCredentials: any VoiceCredentialStoring
    private var epoch = 0
    private var initialText = ""
    private var latestItem: String?
    private var sourceText: String?
    private var responseSources: [String: String] = [:]
    private var currentResponse: String?
    private var suppressed: Set<String> = []
    private var finishedResponses: Set<String> = []
    private var captions: [String: String] = [:]
    private var played: Set<String> = []
    private var pendingTools: [(id: String, name: String, arguments: String, sourceID: String?)] = []
    private var toolDeadline: Task<Void, Never>?
    private var memoryAllowed = false
    private var manuallyInterrupted = false
    var isActive: Bool { state != .idle }

    init(defaults: UserDefaults = .standard, credentials: (any VoiceCredentialStoring)? = nil, doubaoCredentials: (any VoiceCredentialStoring)? = nil, driver: any RealtimeDriving, doubaoDriver: (any RealtimeDriving)? = nil) {
        self.defaults = defaults; self.openAICredentials = SessionCredentials(credentials ?? VoiceKeychain(service: "com.huian.herhis.openai"))
        self.doubaoCredentials = SessionCredentials(doubaoCredentials ?? VoiceKeychain(service: "com.huian.herhis.doubao"))
        self.openAIDriver = driver; self.doubaoDriver = doubaoDriver ?? DoubaoRealtime()
        let provider = RealtimeProvider(rawValue: defaults.string(forKey: "realtimeProvider") ?? "") ?? .openAI
        self.provider = provider
        enabled = defaults.bool(forKey: "realtimeEnabled")
        model = defaults.string(forKey: provider == .doubao ? "doubaoModel" : "realtimeModel") ?? provider.defaultModel
        voice = defaults.string(forKey: provider == .doubao ? "doubaoVoice" : "realtimeVoice") ?? provider.defaultVoice
    }
    func saveKey() {
        stop()
        var key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { message = "请粘贴有效的服务凭证。"; return }
        if provider == .doubao {
            let value = DoubaoCredentials(appID: appIDDraft.trimmingCharacters(in: .whitespacesAndNewlines), accessToken: key)
            do { _ = try value.request(); key = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
            catch { message = DoubaoError.credentials.localizedDescription; return }
        }
        do { try credentials.save(key); keyDraft = ""; appIDDraft = ""; message = "Key 已保存到钥匙串。开启对话时验证账号与额度。" }
        catch { message = "无法保存钥匙串，请检查 macOS 访问权限。" }
    }
    func removeKey() {
        stop(); keyDraft = ""; appIDDraft = ""
        do { try credentials.delete(); enabled = false; message = "已移除\(provider.title)凭证。" }
        catch { message = "密钥未能移除，请检查 macOS 钥匙串权限。" }
    }
    func requireKey() throws -> String {
        guard let key = try credentials.read(), !key.isEmpty else { if provider == .doubao { throw DoubaoError.credentials }; throw RealtimeError.missingKey }
        return key
    }
    func start(configuration: RealtimeConfiguration, initialText: String = "") throws {
        stop()
        let key = try requireKey()
        let token = epoch
        self.initialText = initialText; memoryAllowed = configuration.memoryEnabled
        state = .connecting
        driver.onReady = { [weak self] in
            guard let self, self.epoch == token, self.state == .connecting else { return }
            self.message = "实时语音已连接。"
            self.state = .listening
            let text = self.initialText; self.initialText = ""
            if !text.isEmpty { self.sendText(text) }
        }
        driver.onEvent = { [weak self] event in
            guard let self, self.epoch == token, self.isActive else { return }
            self.receive(event)
        }
        driver.onFailure = { [weak self] message in
            guard let self, self.epoch == token, self.isActive else { return }
            self.fail(message)
        }
        driver.start(key: key, configuration: configuration)
    }
    func stop() {
        epoch += 1
        for value in [openAIDriver, doubaoDriver] {
            value.onReady = nil; value.onEvent = nil; value.onFailure = nil; value.stop()
        }
         toolDeadline?.cancel(); toolDeadline = nil
        pendingTools.removeAll(); latestItem = nil; sourceText = nil; currentResponse = nil
        captions.removeAll(); suppressed.removeAll(); played.removeAll(); responseSources.removeAll(); finishedResponses.removeAll()
        initialText = ""; manuallyInterrupted = false; state = .idle
    }
    func interrupt() {
        guard isActive, state != .connecting else { return }
        manuallyInterrupted = true
        suppressCurrent()
        driver.interrupt(); state = .listening
    }
    private func suppressCurrent() {
        if let currentResponse { suppressed.insert(currentResponse); captions[currentResponse] = nil }
        toolDeadline?.cancel(); toolDeadline = nil
        // A new user turn must not let an earlier delayed transcript write a memory.
        for tool in pendingTools { toolResult(tool.id, "未保存：用户已开始新的输入。") }
        pendingTools.removeAll()
    }
    func sendText(_ text: String) {
        guard isActive, state != .connecting, !text.isEmpty else { return }
        interrupt()
        manuallyInterrupted = false; currentResponse = nil
        let id = "item_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        latestItem = id; sourceText = String(text.prefix(4000))
        driver.send(["type": "conversation.item.create", "item": ["id": id, "type": "message", "role": "user", "content": [["type": "input_text", "text": sourceText!]]]])
        onUserTranscript?(sourceText!)
        guard isActive else { return }
        driver.send(["type": "response.create"]); state = .thinking
    }
    private func receive(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "input_audio_buffer.speech_started":
            suppressCurrent(); manuallyInterrupted = false; currentResponse = nil
            latestItem = nil; sourceText = nil; state = .listening
        case "input_audio_buffer.speech_stopped": state = .thinking
        case "input_audio_buffer.committed":
            latestItem = event["item_id"] as? String; sourceText = nil
        case "conversation.item.input_audio_transcription.completed":
            guard let id = event["item_id"] as? String, id == latestItem, let text = event["transcript"] as? String, !text.isEmpty else { return }
            sourceText = String(text.prefix(4000)); onUserTranscript?(sourceText!)
            guard isActive else { return }
            finishToolsIfPossible()
        case "conversation.item.input_audio_transcription.failed":
            guard let id = event["item_id"] as? String, id == latestItem else { return }
            sourceText = nil; rejectPendingTools("未保存：本轮转写未成功。")
            message = "这句话的字幕不可用；不会据此保存记忆。声音对话仍可继续。"
        case "response.created":
            guard let response = event["response"] as? [String: Any], let id = response["id"] as? String else { return }
            currentResponse = id
            if manuallyInterrupted { suppressed.insert(id); driver.interrupt(); return }
            if let latestItem { responseSources[id] = latestItem }
            state = .thinking
        case "output_audio_buffer.started":
            guard !manuallyInterrupted else { return }; state = .speaking
        case "response.output_audio_transcript.done":
            guard let id = event["response_id"] as? String, !suppressed.contains(id), let text = event["transcript"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            captions[id] = String(text.prefix(8000)); publishCaption(id)
        case "output_audio_buffer.stopped":
            if let id = event["response_id"] as? String { played.insert(id); publishCaption(id) }
            state = .listening
        case "output_audio_buffer.cleared": state = .listening
        case "response.done":
            guard let response = event["response"] as? [String: Any], let id = response["id"] as? String,
                  !finishedResponses.contains(id) else { return }
            finishedResponses.insert(id)
            guard !manuallyInterrupted, !suppressed.contains(id) else { return }
            if response["status"] as? String == "failed" { fail(RealtimeError.unavailable.localizedDescription); return }
            if response["status"] as? String == "cancelled" { suppressed.insert(id); captions[id] = nil; return }
            let calls = (response["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "function_call" }
            for call in calls.prefix(8) {
                guard let callID = call["call_id"] as? String else { continue }
                pendingTools.append((callID, call["name"] as? String ?? "", call["arguments"] as? String ?? "", responseSources[id]))
            }
            finishToolsIfPossible()
            if !pendingTools.isEmpty {
                let token = epoch
                toolDeadline?.cancel()
                toolDeadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    guard let self, self.epoch == token, self.isActive else { return }
                    self.rejectPendingTools("未保存：没有收到可核对的本轮原话。")
                }
            }
        case "error":
            let code = (event["error"] as? [String: Any])?["code"] as? String ?? ""
            if ["response_cancel_not_active", "output_audio_buffer_empty"].contains(code) { return }
            fail((code.contains("quota") || code.contains("rate_limit") ? RealtimeError.quota : RealtimeError.unavailable).localizedDescription)
        default: break
        }
    }
    private func publishCaption(_ id: String) {
        guard played.contains(id), !suppressed.contains(id), let text = captions.removeValue(forKey: id) else { return }
        onAssistantTranscript?(text)
        let source = responseSources[id] != nil && responseSources[id] == latestItem ? sourceText : nil
        onAssistantTestRecord?(text, source)
    }
    private func toolResult(_ callID: String, _ result: String) {
        driver.send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": result]])
    }
    private func finishToolsIfPossible() {
        guard !pendingTools.isEmpty, let sourceText else { return }
        toolDeadline?.cancel(); toolDeadline = nil
        let tools = pendingTools; pendingTools.removeAll()
        for tool in tools {
            let valid = memoryAllowed && tool.name == "update_memory" && tool.arguments.utf8.count <= 16384 && tool.sourceID != nil && tool.sourceID == latestItem
            let result = valid ? (onMemoryUpdate?(tool.arguments, sourceText) ?? "未保存：记忆不可用。") : "未保存：请求失效或没有权限。"
            guard isActive else { return }
            toolResult(tool.id, result)
        }
        if isActive { driver.send(["type": "response.create"]) }
    }
    private func rejectPendingTools(_ reason: String) {
        guard !pendingTools.isEmpty else { return }
        for tool in pendingTools { toolResult(tool.id, reason) }
        pendingTools.removeAll(); toolDeadline?.cancel(); toolDeadline = nil
        if isActive { driver.send(["type": "response.create"]) }
    }
    private func fail(_ text: String) { stop(); message = text; onFailure?(text) }
}
