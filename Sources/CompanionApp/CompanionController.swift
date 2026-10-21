import SwiftUI
import AppKit
import Combine
import CompanionCore

struct ConversationLine: Identifiable {
    let id = UUID()
    let role: String
    let text: String
}

enum PresencePhase: String {
    case off, waiting, connecting, listening, thinking, speaking, muted, unavailable
    var title: String {
        switch self {
        case .off: return "安静地在这里"
        case .waiting: return "等你叫我的名字"
        case .connecting: return "正在接通…"
        case .listening: return "我在听"
        case .thinking: return "想一想，再回应你"
        case .speaking: return "正在回应你"
        case .muted: return "麦克风已静音"
        case .unavailable: return "连接暂时停下了"
        }
    }
}

@MainActor
final class CompanionController: ObservableObject {
    @Published private(set) var phase: PresencePhase = .off
    @Published private(set) var lines: [ConversationLine] = []
    @Published private(set) var memories: [CompanionMemory] = []
    @Published private(set) var wakeEnabled = false
    @Published private(set) var memoryEnabled: Bool
    @Published private(set) var testRecordingEnabled: Bool
    @Published private(set) var testRecordingError: String?
    @Published private(set) var modelAvailable = false
    @Published private(set) var checkingConnection = false
    @Published private(set) var status = "本机模型 · 尚未连接"
    @Published var errorText: String?
    @Published var draft = ""
    @Published var companionName: String
    @Published var modelName: String
    @Published var selectedPage = "presence"
    @Published private(set) var partial = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var speechAvailable = false
    @Published var showWelcome: Bool
    let dataURL: URL
    let callHistory: CallHistoryModel
    private var historyChanges: AnyCancellable?
    var testJournalURL: URL { dataURL.deletingLastPathComponent().appendingPathComponent("test-records.json") }
    private lazy var testJournal = TestJournal(fileURL: testJournalURL)
    private var suppressTestReply = false
    let speech: any SpeechDriving
    let cloudVoice: CloudVoiceOutput
    let realtime: RealtimeConversation
    private var realtimeChanges: AnyCancellable?
    private let defaults: UserDefaults
    private let clientFactory: (String) -> any ModelServing
    private let localRuntime: any LocalModelStarting
    private var connectionEpoch = 0
    private var connectionErrorText: String?
    private var store: MemoryStore?
    private var gate = TurnGate()
    private var history: [ChatMessage] = []
    private var continuityContext = ""
    private var realtimeMemory: Task<Void, Never>?
    private var realtimeMemoryQueue: [String] = []
    private var memoryJobEpoch = 0
    private var realtimeMemoryError: String?
    private var generation: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var lastPartial = ""
    private var lastSpoken = ""
    private var completingWakeUtterance = false
    private var voiceEpoch = 0
    private var textOnly = true
    private var listeningOnly = false
    private var phoneCall = false
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var sleepObserver: NSObjectProtocol?

    init(dataURL: URL? = nil, speech: (any SpeechDriving)? = nil, defaults: UserDefaults = .standard, cloudVoice: CloudVoiceOutput? = nil, realtime: RealtimeConversation? = nil, localRuntime: (any LocalModelStarting)? = nil, clientFactory: @escaping (String) -> any ModelServing = { OllamaClient(model: $0) }) {
        self.defaults = defaults
        let cloudVoice = cloudVoice ?? CloudVoiceOutput(defaults: defaults)
        self.cloudVoice = cloudVoice
        self.realtime = realtime ?? RealtimeConversation(defaults: defaults, driver: RealtimeWebRTC())
        self.speech = speech ?? SpeechService(cloudVoice: cloudVoice)
        self.clientFactory = clientFactory
        self.localRuntime = localRuntime ?? LocalModelRuntime()
        let speech = self.speech
        companionName = defaults.string(forKey: "companionName") ?? "小禾"
        modelName = defaults.string(forKey: "modelName") ?? "qwen3:4b"
        memoryEnabled = defaults.object(forKey: "memoryEnabled") as? Bool ?? true
        testRecordingEnabled = defaults.bool(forKey: "testRecordingEnabled")
        showWelcome = !defaults.bool(forKey: "welcomeSeen")
        self.dataURL = dataURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerHis", isDirectory: true).appendingPathComponent("memories.json")
        callHistory = CallHistoryModel(fileURL: self.dataURL.deletingLastPathComponent().appendingPathComponent("call-history.json"), defaults: defaults)
        do {
            store = try MemoryStore(fileURL: self.dataURL, ownerID: NSUserName())
            memories = store?.memories ?? []
        } catch { errorText = "记忆文件暂时无法读取，已保留原文件。\(error.localizedDescription)" }
        speech.onPartial = { [weak self] text, final in self?.hear(text, final: final) }
        speech.onFailure = { [weak self] message in
            guard let self else { return }
            self.disableVoice()
            self.phase = .unavailable
            self.errorText = message
        }
        speech.onLevel = { [weak self] value in self?.level = value }
        speech.onPlaybackFailure = { [weak self] message in self?.errorText = message }
        speech.onSpeechFinished = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.phase = self.gate.isOpen ? .listening : (self.wakeEnabled ? .waiting : .off)
            self.lastSpoken = ""
            self.lastPartial = ""
            if self.speech.isRunning {
                do { try self.speech.resetRecognition() } catch { self.speechFailed(error) }
            }
        }
        self.realtime.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle: break
            case .connecting: self.phase = .connecting
            case .listening: self.phase = .listening
            case .thinking: self.phase = .thinking
            case .speaking: self.phase = .speaking
            }
        }
        self.realtime.onTextNotSent = { [weak self] text in
            guard let self else { return }
            if self.draft.isEmpty { self.draft = text }
            self.errorText = "记忆同步尚未确认，这条文字没有发送。声音可继续；重新开启对话后可再发送。"
        }
        self.realtime.onUserTranscript = { [weak self] text in self?.receiveRealtimeTranscript(text) }
        self.realtime.onAssistantTranscript = { [weak self] text in
            guard let self else { return }
            self.appendLine(role: "assistant", text: text, record: false); self.trimRealtimeLines()
        }
        self.realtime.onAssistantTestRecord = { [weak self] text, source in
            let allowed = source.map { !MemoryPolicy.preventMemoryStorage(in: $0) } ?? false
            let savedText = allowed ? text : "[原话未就绪或隐私回合，回答文字已省略]"
            self?.recordTest("assistant", savedText)
            self?.callHistory.append(role: "assistant", text: savedText)
        }
        self.realtime.onMemoryUpdate = { [weak self] args, source in self?.applyRealtimeMemory(args, source: source) ?? "未保存：记忆不可用。" }
        self.realtime.onFailure = { [weak self] message in
            guard let self else { return }; self.disableVoice(); self.phase = .unavailable; self.errorText = message
        }
        realtimeChanges = self.realtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        callHistory.onRecallInvalidated = { [weak self] in
            guard let self, !self.continuityContext.isEmpty else { return }
            self.disableVoice()
            self.errorText = "续聊内容已撤回，通话已结束。重新打电话后使用当前设置与保留的记录。"
        }
        historyChanges = callHistory.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        sleepObserver = workspaceNotifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForSleep() }
        }
        if testRecordingEnabled { recordTest("status", "应用启动，本机测试记录开启") }
    }

    deinit {
        if let sleepObserver { workspaceNotifications.removeObserver(sleepObserver) }
    }
    private func prepareForSleep() {
        guard callInProgress || isMuted else { return }
        disableVoice()
        errorText = "Mac 即将休眠，通话已结束。唤醒后点“打电话”即可重新接通。"
    }
    var microphoneRunning: Bool { speech.isRunning || realtime.isActive }
    var recordingDescription: String {
        if callHistory.enabled { return testRecordingEnabled ? "本机通话历史与测试记录已开启 · 不保存录音" : "本机通话历史已开启 · 不保存录音" }
        return testRecordingEnabled ? "历史保存关闭 · 本机测试记录仍在保存文字" : "历史与测试记录关闭 · 不新增聊天记录"
    }
    func setTestRecordingEnabled(_ enabled: Bool) {
        testRecordingEnabled = enabled; defaults.set(enabled, forKey: "testRecordingEnabled")
        if enabled { recordTest("status", "本机测试记录已开启") }
    }
    func clearTestRecords() {
        do { try testJournal.clear(); testRecordingError = nil }
        catch { testRecordingError = "测试记录未能清空，请查看数据位置。" }
    }
    private func recordTest(_ kind: String, _ text: String) {
        do { try testJournal.append(kind: kind, text: text, enabled: testRecordingEnabled); testRecordingError = nil }
        catch { testRecordingError = "本机测试记录写入失败，原记录已保留。" }
    }
    private func appendLine(role: String, text: String, record: Bool = true) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append(.init(role: role, text: text))
        guard record else { return }
        if role == "user" { suppressTestReply = MemoryPolicy.preventMemoryStorage(in: text) }
        let savedText = suppressTestReply ? "[隐私回合内容已省略]" : text
        recordTest(role, savedText)
        callHistory.append(role: role, text: savedText)
    }
    var micDescription: String {
        if realtime.isActive { return realtime.state == .connecting ? "正在连接 · 请稍等再说" : "实时语音 · 音频传至 \(realtime.provider.title)" }

        guard speech.isRunning else { return "麦克风关闭" }
        return phase == .waiting ? "仅在本机检测呼唤" : "本机听写 · 不保存录音"
    }
    var canEnd: Bool { gate.isOpen || realtime.isActive }
    var callInProgress: Bool { phase == .connecting || wakeEnabled || microphoneRunning || canEnd }
    var isMuted: Bool { phase == .muted }

    func startCall() {
        guard !callInProgress else { return }
        phoneCall = true; phase = .off
        enableVoice(startConversation: true)
    }

    func previewVoice() {
        // The fixed sample must not be transcribed as a new conversation turn.
        // Also invalidate an enableVoice() still awaiting the permission dialog.
        voiceEpoch += 1
        if phoneCall { disableVoice() }
        else if microphoneRunning { mute() }
        else { interrupt() }
        cloudVoice.preview()
    }

    func acknowledgeWelcome() {
        defaults.set(true, forKey: "welcomeSeen")
        showWelcome = false
    }
    func saveSettings() {
        if realtime.isActive { disableVoice() }
        let clean = companionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, clean.count <= 8 else {
            errorText = "名字请使用 2–8 个字。"; return
        }
        guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "请填写本机已有的模型名称。"; return
        }
        companionName = clean
        speech.contextPhrases = [clean]
        resetInputContext()
        defaults.set(clean, forKey: "companionName")
        defaults.set(modelName, forKey: "modelName")
        lastPartial = ""
        cancelOutput()
        if gate.isOpen { phase = .listening }
        if !realtime.enabled { Task { await checkConnection() } }
    }

    func checkConnection() async {
        guard !realtime.enabled else { status = "实时语音在开启对话时连接"; return }
        guard !checkingConnection else { return }
        checkingConnection = true
        let checkedModel = modelName
        let epoch = connectionEpoch
        if errorText == connectionErrorText { errorText = nil }
        connectionErrorText = nil
        status = "正在连接本机对话引擎…"
        defer { checkingConnection = false }
        do {
            let models = try await LocalModelConnection.connect(client: clientFactory(checkedModel), runtime: localRuntime,
                cancelled: { self.connectionEpoch != epoch },
                preparing: { self.status = "正在自动启动本机对话引擎…" })
            guard epoch == connectionEpoch, checkedModel == modelName, !Task.isCancelled else { return }
            modelAvailable = models.contains(checkedModel)
            status = modelAvailable ? "本机模型已连接 · \(modelName)" : "Ollama 已连接 · 尚无 \(modelName)"
            if !modelAvailable {
                connectionErrorText = "本机引擎已启动，但没有 \(checkedModel)。请在设置中选择已有模型，或在 Ollama 中下载。"
                errorText = connectionErrorText
            }
        } catch is CancellationError { return }
        catch {
            guard epoch == connectionEpoch, checkedModel == modelName else { return }
            modelAvailable = false
            status = "本机对话暂未就绪"
            connectionErrorText = error.localizedDescription
            errorText = connectionErrorText
        }
    }

    func enableVoice(startConversation: Bool = false) {
        guard phase != .muted else { unmute(); return }
        if realtime.enabled && startConversation { startRealtime(); return }
        if realtime.enabled {
            do { _ = try realtime.requireKey() }
            catch { errorText = error.localizedDescription; selectedPage = "settings"; return }
        }
        cancelOutput()
        voiceEpoch += 1
        let epoch = voiceEpoch
        errorText = nil
        if startConversation { phase = .connecting }
        Task {
            do {
                try await speech.requestPermission()
                guard epoch == voiceEpoch else { return }
                speech.contextPhrases = [companionName]
                try speech.start()
                speechAvailable = true; wakeEnabled = true; textOnly = false
                lastPartial = ""
                if startConversation { openConversation() }
                else { gate.close(); history.removeAll(); lines.removeAll(); phase = .waiting }
            } catch {
                guard epoch == voiceEpoch else { return }
                speech.stop(); speechAvailable = false; wakeEnabled = false; textOnly = true; phoneCall = false
                phase = .unavailable
                errorText = error.localizedDescription
            }
        }
    }

    func disableVoice() {
        continuityContext = ""
        callHistory.finish()
        phoneCall = false
        realtime.stop()
        voiceEpoch += 1
        wakeEnabled = false; speechAvailable = false; textOnly = true
        cancelOutput(); speech.stop(); gate.close(); listeningOnly = false
        history.removeAll(); lines.removeAll(); partial = ""; level = 0; lastPartial = ""; completingWakeUtterance = false
        phase = .off
    }
    func mute() {
        continuityContext = ""
        callHistory.finish()
        realtime.stop()
        voiceEpoch += 1
        cancelOutput(); speech.stop(); partial = ""; level = 0
        speechAvailable = false; phase = .muted
    }
    func unmute() {
        phase = .off
        enableVoice(startConversation: gate.isOpen)
    }
    func interrupt() {
        if realtime.isActive { realtime.interrupt(); return }
        cancelOutput()
        if gate.isOpen && phase != .muted { phase = .listening }
    }
    func endConversation() {
        if phoneCall { disableVoice(); return }
        continuityContext = ""
        callHistory.finish()
        let wasRealtime = realtime.isActive
        realtime.stop()
        let wasMuted = isMuted
        voiceEpoch += 1
        cancelOutput(); gate.close(); listeningOnly = false
        history.removeAll(); lines.removeAll(); partial = ""; lastPartial = ""; completingWakeUtterance = false
        if wasRealtime && wakeEnabled && !wasMuted {
            phase = .off; enableVoice()
        } else if wakeEnabled && speech.isRunning {
            phase = .waiting
            do { try speech.resetRecognition() } catch { speechFailed(error) }
        } else { phase = wasMuted ? .muted : .off }
    }
    private func openConversation() {
        continuityContext = memoryEnabled ? callHistory.continuity(companion: companionName) : ""
        callHistory.begin(companion: companionName, provider: "本机")
        cancelOutput(); gate.open(); listeningOnly = false; history.removeAll(); lines.removeAll()
        phase = .listening; partial = ""; lastPartial = ""; completingWakeUtterance = false
    }
    private func cancelOutput() {
        cancelRealtimeMemory()
        gate.invalidate(); generation?.cancel(); generation = nil
        debounce?.cancel(); debounce = nil
        if phase == .speaking { phase = .listening }
        speech.stopSpeaking(); lastSpoken = ""
    }
    private func speechFailed(_ error: Error) {
        disableVoice()
        phase = .unavailable
        errorText = error.localizedDescription
    }
    private func resetInputContext() {
        partial = ""; lastPartial = ""; completingWakeUtterance = false
        if speech.isRunning {
            do { try speech.resetRecognition() } catch { speechFailed(error) }
        }
    }
    private func normalized(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func hear(_ text: String, final: Bool) {
        guard speech.isRunning, phase != .muted else { return }
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if phase == .waiting {
            guard WakeMatcher.remainder(in: clean, name: companionName) != nil else {
                // Clear an ignored background utterance at silence, without opening a turn.
                debounce?.cancel()
                let epoch = voiceEpoch
                debounce = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: final ? 350_000_000 : 1_100_000_000) } catch { return }
                    guard let self, !Task.isCancelled, self.voiceEpoch == epoch, self.phase == .waiting else { return }
                    self.resetInputContext()
                }
                return
            }
            openConversation()
            completingWakeUtterance = true
        }
        // Recognition partials include the entire utterance. Keep the same recognition
        // request through wake + content so "小禾，今天有点累" becomes one turn.
        if completingWakeUtterance {
            clean = WakeMatcher.remainder(in: clean, name: companionName) ?? clean
        }
        guard gate.isOpen else { return }
        if speech.isSpeaking {
            let candidate = normalized(clean), spoken = normalized(lastSpoken)
            // Echo filter is conservative; actual speaker/headphone routes still require acceptance testing.
            if !candidate.isEmpty && !spoken.isEmpty && (spoken.contains(candidate) || candidate.contains(spoken)) { return }
            interrupt()
        }
        guard clean != lastPartial || completingWakeUtterance || final else { return }
        if phase == .thinking { interrupt() }
        lastPartial = clean; partial = clean
        debounce?.cancel()
        let epoch = voiceEpoch
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: final ? 350_000_000 : 1_100_000_000) } catch { return }
            guard let self, !Task.isCancelled, epoch == self.voiceEpoch, self.gate.isOpen else { return }
            let nameOnly = self.completingWakeUtterance && clean.isEmpty
            self.completingWakeUtterance = false
            self.partial = ""; self.lastPartial = ""
            do { try self.speech.resetRecognition() } catch { self.speechFailed(error); return }
            if self.realtime.enabled { self.startRealtime(initialText: clean) }
            else if nameOnly { self.speak("嗯，我在。") }
            else { self.submit(clean) }
        }
    }

    func sendDraft() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, phase != .muted else { return }
        if realtime.enabled {
            guard realtime.state != .connecting else { return }
            draft = ""
            if realtime.isActive { realtime.sendText(value) } else { startRealtime(initialText: value) }
            return
        }
        draft = ""
        resetInputContext()
        if !gate.isOpen { textOnly = !speech.isRunning; openConversation() }
        submit(value)
    }
    private func speak(_ value: String) {
        guard !textOnly, speech.isRunning, phase != .muted else {
            phase = gate.isOpen ? .listening : (wakeEnabled ? .waiting : .off)
            return
        }
        lastSpoken = value; phase = .speaking; speech.speak(value)
    }
    private func hasForgetIntent(_ text: String) -> Bool {
        MemoryPolicy.hasForgetIntent(in: text)
    }

    func submit(_ raw: String) {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
        guard !text.isEmpty, phase != .muted else { return }
        errorText = nil
        if !gate.isOpen { openConversation() }
        cancelOutput()
        let command = normalized(text)
        if ["关闭麦克风", "停止监听", "关闭语音唤起"].contains(command) { appendLine(role: "user", text: text); disableVoice(); return }
        if ["晚安", "我要睡了", "我要睡了晚安", "不聊了", "结束对话", "不是叫你"].contains(command) {
            let farewell = text.contains("晚安") || text.contains("睡") ? "晚安。" : "好。"
            if command != "不是叫你" {
                appendLine(role: "user", text: text)
                if !phoneCall, !textOnly, speech.isRunning { appendLine(role: "assistant", text: farewell) }
            }
            endConversation()
            if command != "不是叫你" { speak(farewell) }
            return
        }
        if ["忘掉所有记忆", "清除全部记忆", "删除所有记忆"].contains(command) {
            clearMemories(); return
        }
        guard modelAvailable else {
            errorText = "本机模型还没有连接。请打开 Ollama，并在设置里检查连接。"; phase = .listening; return
        }
        if let preference = ReplyPolicy.listeningPreference(in: text) { listeningOnly = preference }
        let forget = hasForgetIntent(text)
        let privateTurn = MemoryPolicy.preventMemoryStorage(in: text)
        if privateTurn { store?.invalidatePending(); resetInputContext() }
        appendLine(role: "user", text: text)
        history.append(ChatMessage(role: "user", content: text))
        if history.count > 24 { history.removeFirst(history.count - 24) }
        if lines.count > 24 { lines.removeFirst(lines.count - 24) }
        guard let token = gate.beginTurn() else { return }
        let revision = store?.revision ?? 0
        var requestHistory = Array(history.suffix(23))
        if listeningOnly { requestHistory.insert(ChatMessage(role: "user", content: "这次对话我只想让你听，不要给建议。"), at: 0) }
        if privateTurn { history.removeAll() }
        let continuity = continuityContext
        let memorySnapshot = memories
        let client = clientFactory(modelName)
        let name = companionName
        phase = .thinking
        generation = Task { [weak self] in
            do {
                let response = try await client.respond(messages: requestHistory, memories: memorySnapshot, name: name, continuity: continuity)
                guard let self, !Task.isCancelled, self.gate.accepts(token) else { return }
                if let issue = response.memoryIssue { self.errorText = issue }
                var answer = response.reply
                if privateTurn { self.history.removeAll() }
                if let store = self.store, store.revision == revision {
                    do {
                        if forget {
                            let matched = store.memories.filter { response.forgetKeys.contains($0.key) }
                            self.continuityContext = ""; self.callHistory.excludePastFromRecall()
                            for item in matched { try store.delete(id: item.id) }
                            answer = matched.isEmpty
                                ? "这句话不会保存为记忆。暂时没找到要删除的已有记忆，你也可以在“慢慢记得”里直接删除。"
                                : "已删除对应的记忆，这句话也不会保存。"
                        } else {
                            let changed = try store.apply(candidates: response.memories, source: text, expectedRevision: revision, enabled: self.memoryEnabled)
                            self.recordTest("memory", changed ? "已保存本机对话记忆" : "本机对话无新增记忆")
                        }
                        self.memories = store.memories
                    } catch {
                        self.memories = store.memories
                        self.errorText = "这次记忆操作没有完成：\(error.localizedDescription)"
                        if forget { answer = "这次删除没有全部完成，请到记忆页查看剩余内容。" }
                    }
                } else if forget {
                    answer = "记忆暂时无法操作，这次没有删除成功。"
                }
                if response.endConversation && !forget {
                    self.callHistory.append(role: "assistant", text: privateTurn ? "[隐私回合内容已省略]" : answer)
                    self.endConversation()
                    self.appendLine(role: "assistant", text: answer)
                    self.speak(answer)
                    return
                }
                if !privateTurn { self.history.append(ChatMessage(role: "assistant", content: answer)) }
                self.appendLine(role: "assistant", text: answer)
                self.phase = .listening
                self.speak(answer)
            } catch {
                guard let self, !Task.isCancelled, self.gate.accepts(token) else { return }
                self.endConversation()
                self.errorText = "这次没有接上，对话已停下。可以重新打电话。\(error.localizedDescription)"
            }
        }
    }

    func setMemoryEnabled(_ enabled: Bool) {
        if !enabled { callHistory.excludePastFromRecall() }; continuityContext = ""
        if realtime.isActive { disableVoice() }
        cancelOutput(); store?.invalidatePending(); resetInputContext(); history.removeAll(); lines.removeAll()
        memoryEnabled = enabled; defaults.set(enabled, forKey: "memoryEnabled")
        if gate.isOpen { phase = .listening }
    }
    func deleteMemory(_ id: UUID) {
        callHistory.excludePastFromRecall(); continuityContext = ""
        if realtime.isActive { disableVoice() }
        cancelOutput(); resetInputContext(); history.removeAll(); lines.removeAll()
        do { guard let store else { throw MemoryStoreError.corruptFile }; try store.delete(id: id); memories = store.memories }
        catch { errorText = "未能删除，内容仍保留：\(error.localizedDescription)" }
        if gate.isOpen { phase = .listening }
    }
    func editMemory(_ id: UUID, content: String) {
        callHistory.excludePastFromRecall(); continuityContext = ""
        if realtime.isActive { disableVoice() }
        cancelOutput(); resetInputContext(); history.removeAll(); lines.removeAll()
        do { guard let store else { throw MemoryStoreError.corruptFile }; try store.edit(id: id, content: content); memories = store.memories }
        catch { errorText = "未能保存更改：\(error.localizedDescription)" }
        if gate.isOpen { phase = .listening }
    }
    func clearMemories() {
        callHistory.excludePastFromRecall(); continuityContext = ""
        if realtime.isActive { disableVoice() }
        cancelOutput(); resetInputContext(); history.removeAll(); lines.removeAll()
        do { guard let store else { throw MemoryStoreError.corruptFile }; try store.clear(); memories = store.memories }
        catch { errorText = "未能清除，原内容仍保留：\(error.localizedDescription)" }
        if gate.isOpen { phase = .listening }
    }
    func setRealtimeEnabled(_ enabled: Bool) {
        disableVoice(); connectionEpoch += 1
        realtime.enabled = enabled; errorText = nil
        if !enabled { Task { await checkConnection() } }
    }
    private func startRealtime(initialText: String = "") {
        voiceEpoch += 1; cancelOutput(); speech.stop(); realtime.stop()
        gate.open(); history.removeAll(); lines.removeAll(); partial = ""; lastPartial = ""
        wakeEnabled = true; speechAvailable = true; textOnly = false; errorText = nil
        continuityContext = memoryEnabled ? callHistory.continuity(companion: companionName) : ""
        callHistory.begin(companion: companionName, provider: realtime.provider.title)
        do {
            try realtime.start(configuration: .init(name: companionName, model: realtime.model, voice: realtime.voice,
                                                    memories: memories, memoryEnabled: memoryEnabled, continuity: continuityContext), initialText: initialText)
        } catch {
            disableVoice(); errorText = error.localizedDescription; selectedPage = "settings"
        }
    }
    private func receiveRealtimeTranscript(_ text: String) {
        guard realtime.isActive else { return }
        appendLine(role: "user", text: text); trimRealtimeLines()
        let command = normalized(text)
        if ["关闭麦克风", "停止监听", "关闭语音唤起"].contains(command) { disableVoice() }
        else if ["晚安", "我要睡了", "结束这次对话", "先不聊了"].contains(command) { endConversation() }
        else if realtime.provider == .doubao {
            if ["忘掉所有记忆", "清除全部记忆", "删除所有记忆"].contains(command) { clearMemories(); return }
            if MemoryPolicy.hasForgetIntent(in: text) {
                disableVoice(); selectedPage = "memories"
                errorText = "这句话不会保存。请在这里删除你想忘记的内容；云端会话已结束。"
            } else { extractDoubaoMemory(text) }
        }
    }
    private func cancelRealtimeMemory() {
        if realtimeMemory != nil { recordTest("memory_cancelled", "关麦、会话结束或记忆变更：待处理记忆已取消") }
        memoryJobEpoch += 1; realtimeMemory?.cancel(); realtimeMemory = nil; realtimeMemoryQueue.removeAll()
    }
    private func showMemoryFailure(_ message: String) {
        recordTest("memory_error", message)
        realtimeMemoryError = message; errorText = message
    }
    private func clearMemoryFailure() {
        if let previous = realtimeMemoryError, errorText == previous { errorText = nil }
        realtimeMemoryError = nil
    }
    private func extractDoubaoMemory(_ source: String) {
        guard memoryEnabled, let store else { return }
        if MemoryPolicy.preventMemoryStorage(in: source) { cancelRealtimeMemory(); store.invalidatePending(); return }
        guard MemoryPolicy.hasDeclarativeEvidence(source, in: source) else { return }
        guard realtimeMemoryQueue.count < 16 else {
            showMemoryFailure("自动记忆正在整理前面的内容，这句话暂未保存。声音对话可以继续。"); return
        }
        realtimeMemoryQueue.append(source)
        guard realtimeMemory == nil else { return }
        let token = voiceEpoch, job = memoryJobEpoch
        realtimeMemory = Task { [weak self] in
            guard let self else { return }
            defer { if self.memoryJobEpoch == job { self.realtimeMemory = nil } }
            while !Task.isCancelled, self.voiceEpoch == token, self.memoryJobEpoch == job,
                  self.realtime.isActive, self.memoryEnabled, self.realtime.provider == .doubao,
                  !self.realtimeMemoryQueue.isEmpty {
                let source = self.realtimeMemoryQueue.removeFirst()
                let revision = store.revision, snapshot = self.memories, model = self.modelName
                do {
                    let candidates: [MemoryCandidate]
                    if let birthday = PersonalFacts.birthday(from: source) { candidates = [birthday] }
                    else {
                        let client = self.clientFactory(model)
                        let models = try await LocalModelConnection.connect(client: client, runtime: self.localRuntime,
                            cancelled: { Task.isCancelled || self.voiceEpoch != token || self.memoryJobEpoch != job || !self.realtime.isActive }, preparing: {})
                        guard models.contains(model) else { throw LocalModelStartupError.notReady }
                        candidates = try await client.memoryCandidates(source: source, existing: snapshot)
                    }
                    guard !Task.isCancelled, self.voiceEpoch == token, self.memoryJobEpoch == job,
                          self.realtime.isActive, self.memoryEnabled, store.revision == revision else { continue }
                    let changed = try store.apply(candidates: candidates, source: source, expectedRevision: revision, enabled: true)
                    self.recordTest("memory", "原话：\(source)\n结果：\(changed ? "已保存" : "无新增记忆")；候选主题：\(candidates.map(\.key).joined(separator: ", "))")
                    self.memories = store.memories; self.clearMemoryFailure()
                    if changed { self.realtime.updateMemories(self.memories) }
                } catch {
                    guard !Task.isCancelled, self.voiceEpoch == token, self.memoryJobEpoch == job, self.realtime.isActive else { return }
                    let reason: String
                    if (error as? URLError)?.code == .timedOut { reason = "本机整理超时" }
                    else if let error = error as? ModelClientError {
                        switch error {
                        case .invalidResponse: reason = "本机返回的记忆格式不完整"
                        default: reason = "本机记忆服务未能完成处理"
                        }
                    } else if error is MemoryStoreError { reason = "本机记忆文件未能写入" }
                    else { reason = "本机记忆服务暂未连接" }
                    self.showMemoryFailure("这句话的自动记忆没有保存：\(reason)。声音对话可以继续。")
                }
            }
        }
    }
    private func trimRealtimeLines() { if lines.count > 40 { lines.removeFirst(lines.count - 40) } }
    private func applyRealtimeMemory(_ arguments: String, source: String) -> String {
        guard realtime.isActive, memoryEnabled, let store,
              let data = arguments.data(using: .utf8),
              let update = try? JSONDecoder().decode(RealtimeMemoryUpdate.self, from: data) else { return "未保存：记忆关闭或请求无效。" }
        do {
            if !update.forgetKeys.isEmpty {
                guard MemoryPolicy.hasForgetIntent(in: source) else { return "未删除：没有检测到用户的忘记请求。" }
                let matched = store.memories.filter { update.forgetKeys.prefix(8).contains($0.key) }
                guard !matched.isEmpty else { return "未删除：没有找到对应记忆。" }
                continuityContext = ""; callHistory.excludePastFromRecall()
                for item in matched { try store.delete(id: item.id) }
                memories = store.memories
                // The old session instructions contain the deleted context: close it immediately.
                disableVoice(); errorText = "已删除对应记忆，并结束这次实时对话。重新开启后不会再带入旧内容。"
                return "已删除。"
            }
            let changed = try store.apply(candidates: update.memories, source: source, expectedRevision: store.revision, enabled: memoryEnabled)
            recordTest("memory", changed ? "已保存实时对话记忆" : "实时对话无新增记忆")
            memories = store.memories
            if changed { realtime.updateMemories(memories) }
            return changed ? "记忆已保存到本机。" : "没有新增记忆：内容已存在，或没有通过原话证据与拒存检查。不要宣称保存成功。"
        } catch { memories = store.memories; return "记忆操作未完成，请用户到记忆页查看；不要宣称成功。" }
    }
    func shutdown() {
        if let sleepObserver { workspaceNotifications.removeObserver(sleepObserver); self.sleepObserver = nil }
        connectionEpoch += 1; disableVoice(); localRuntime.stop()
    }
}
