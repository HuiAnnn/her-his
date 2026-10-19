import AVFoundation
import Combine
import CompanionCore
import Foundation

@MainActor protocol VoiceAudioPlaying: AnyObject {
    func play(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) throws
    func stop()
}

@MainActor final class CloudVoiceOutput: ObservableObject {
    static let previewText = "我在。今天过得怎么样？不着急，你可以慢慢说，也可以先安静地待一会儿。"
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "cloudVoiceEnabled") } }
    @Published var voiceID: String { didSet { defaults.set(voiceID, forKey: "cloudVoiceID") } }
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "cloudVoiceModelID") } }
    @Published var keyDraft = ""
    @Published private(set) var voices: [CloudVoice] = []
    @Published private(set) var models: [CloudVoiceModel] = []
    @Published private(set) var loading = false
    @Published private(set) var isBusy = false
    @Published private(set) var message = "尚未连接。保存密钥后，读取声线并试听。"
    private let defaults: UserDefaults
    private let credentials: any VoiceCredentialStoring
    private let client: ElevenLabsClient
    private let player: any VoiceAudioPlaying
    private var generation = 0
    private var catalogGeneration = 0
    private var task: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var completion: ((Result<Void, Error>) -> Void)?

    init(defaults: UserDefaults = .standard, credentials: (any VoiceCredentialStoring)? = nil,
         client: ElevenLabsClient = ElevenLabsClient(), player: (any VoiceAudioPlaying)? = nil) {
        self.defaults = defaults
        self.credentials = SessionCredentials(credentials ?? VoiceKeychain())
        self.client = client
        self.player = player ?? MemoryAudioPlayer()
        enabled = defaults.bool(forKey: "cloudVoiceEnabled")
        voiceID = defaults.string(forKey: "cloudVoiceID") ?? ""
        modelID = defaults.string(forKey: "cloudVoiceModelID") ?? "eleven_v3"
    }

    func saveKey() {
        do {
            let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { throw CloudVoiceError.missingKey }
            stop(); cancelCatalog()
            try credentials.save(key)
            keyDraft = ""
            message = "密钥已存入 macOS 钥匙串。点击“读取声线”验证连接。"
        } catch { message = error.localizedDescription }
    }

    func removeKey() {
        stop(); cancelCatalog()
        do {
            try credentials.delete()
            enabled = false; keyDraft = ""; voices = []; models = []
            message = "已移除密钥，恢复系统声音。"
        } catch { message = error.localizedDescription }
    }

    func loadCatalog() {
        cancelCatalog()
        loading = true
        let token = catalogGeneration
        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try self.key()
                async let availableVoices = client.voices(key: key)
                async let availableModels = client.models(key: key)
                let (voices, models) = try await (availableVoices, availableModels)
                guard token == catalogGeneration, !Task.isCancelled else { return }
                self.voices = voices; self.models = models
                if !models.contains(where: { $0.id == self.modelID }), let first = models.first { modelID = first.id }
                message = voices.isEmpty ? "账户中没有声线，请先去 ElevenLabs 声音库添加。" : "已连接。请选择声线并试听；声音库中的中文声线通常更适合普通话。"
            } catch {
                guard token == catalogGeneration, !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            guard token == catalogGeneration else { return }
            loading = false; catalogTask = nil
        }
    }

    func preview() {
        play(Self.previewText) { [weak self] result in
            if case .success = result { self?.message = "试听结束。喜欢这条声线，可以开启“使用云端声音”。" }
        }
    }

    func play(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        self.completion = completion
        isBusy = true; message = "正在生成声音…"
        let token = generation, voice = voiceID, model = modelID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try self.key()
                let data = try await client.synthesize(text, key: key, voiceID: voice, modelID: model)
                guard token == generation, !Task.isCancelled else { return }
                message = "正在播放…"
                try player.play(data) { [weak self] result in
                    guard let self, token == self.generation else { return }
                    self.finish(result)
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                finish(.failure(error))
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel(); task = nil
        player.stop()
        let callback = completion; completion = nil
        if isBusy { message = "播放已停止。" }
        isBusy = false
        callback?(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        task = nil; isBusy = false
        switch result {
        case .success: message = "播放完成。"
        case .failure(let error): message = error.localizedDescription
        }
        let callback = completion; completion = nil
        callback?(result)
    }

    private func key() throws -> String {
        guard let key = try credentials.read(), !key.isEmpty else { throw CloudVoiceError.missingKey }
        return key
    }

    private func cancelCatalog() {
        catalogGeneration += 1; catalogTask?.cancel(); catalogTask = nil; loading = false
    }
}

/// Holds returned audio only in memory; never caches it in a file.
@MainActor private final class MemoryAudioPlayer: NSObject, VoiceAudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: ((Result<Void, Error>) -> Void)?
    func play(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) throws {
        stop()
        let player: AVAudioPlayer
        do { player = try AVAudioPlayer(data: data) } catch { throw CloudVoiceError.invalidResponse }
        self.player = player; self.completion = completion
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { stop(); throw CloudVoiceError.invalidResponse }
    }
    func stop() { player?.stop(); player = nil; completion = nil }
    private func finished(_ player: AVAudioPlayer, success: Bool) {
        guard self.player === player else { return }
        let callback = completion
        stop()
        callback?(success ? .success(()) : .failure(CloudVoiceError.invalidResponse))
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished(player, success: flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finished(player, success: false) }
    }
}
