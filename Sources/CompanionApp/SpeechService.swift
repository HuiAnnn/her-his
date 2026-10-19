import AVFoundation
import Combine
import Foundation
import Speech
import OSLog

/// Audio and transcripts stay in memory. Every recognition request is explicitly on-device.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    var onPartial: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlaybackFailure: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onSpeechFinished: (() -> Void)?
    var contextPhrases: [String] = []

    @Published private(set) var isRunning = false
    @Published private(set) var isSpeaking = false

    private let audioLog = Logger(subsystem: "com.huian.herhis", category: "AudioHealth")
    private var receivedAudio = false
    private var receivedRecognition = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let sink = RecognitionAudioSink()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rolloverTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var sessionGeneration: UInt64 = 0
    private var recognitionGeneration: UInt64 = 0
    private var lastTranscript = ""
    private var recentErrorRestarts: [TimeInterval] = []
    private var currentUtterance: AVSpeechUtterance?
    private let cloudVoice: CloudVoiceOutput
    private var playbackGeneration = 0

    init(cloudVoice: CloudVoiceOutput) {
        self.cloudVoice = cloudVoice
        super.init()
        synthesizer.delegate = self
        recognizer?.delegate = self
    }

    func requestPermission() async throws {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else {
            speechStatus = SFSpeechRecognizer.authorizationStatus()
        }
        try Task.checkCancellation()
        guard speechStatus == .authorized else { throw ServiceError.speechPermission }

        let microphoneAllowed: Bool
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        try Task.checkCancellation()
        guard microphoneAllowed else { throw ServiceError.microphonePermission }
        _ = try availableRecognizer()
    }

    func start() throws {
        guard !isRunning else { return }
        _ = try availableRecognizer()
        sessionGeneration &+= 1
        let session = sessionGeneration
        recentErrorRestarts.removeAll()
        receivedAudio = false; receivedRecognition = false

        let input = engine.inputNode
        // VoiceProcessingIO faulted in this capture-only graph on the tested Mac,
        // producing continuous invalid-sample-time downlink DSP errors.
        // Keep capture on the standard input unit; playback uses AVSpeechSynthesizer.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ServiceError.microphoneUnavailable
        }

        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let level = sink.consume(buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.sessionGeneration == session else { return }
                if !self.receivedAudio {
                    self.receivedAudio = true
                    self.audioLog.notice("Microphone audio frames received")
                }
                self.onLevel?(level)
            }
        }
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            audioLog.notice("Capture started: sampleRate=\(format.sampleRate), channels=\(format.channelCount), voiceProcessing=false")
            try beginRecognition()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                // Never tear down the engine on its internal notification queue.
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.sessionGeneration == session else { return }
                    self.fail(ServiceError.audioConfigurationChanged.localizedDescription)
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        // Invalidate first, before cancellation can deliver callbacks.
        sessionGeneration &+= 1
        isRunning = false
        cancelRecognition()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.reset()
        recentErrorRestarts.removeAll()
        stopSpeaking()
        onLevel?(0)
    }

    func resetRecognition() throws {
        guard isRunning else { return }
        cancelRecognition()
        do {
            try beginRecognition()
        } catch {
            stop()
            throw error
        }
    }

    func speak(_ text: String) {
        guard isRunning else { return }
        stopSpeaking()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onSpeechFinished?()
            return
        }
        if cloudVoice.enabled {
            isSpeaking = true
            let token = playbackGeneration
            cloudVoice.play(trimmed) { [weak self] result in
                guard let self, token == self.playbackGeneration else { return }
                self.isSpeaking = false
                if case .failure(let error) = result, !(error is CancellationError) {
                    self.onPlaybackFailure?(error.localizedDescription)
                }
                self.onSpeechFinished?()
            }
            return
        }
        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else {
            fail(ServiceError.voiceUnavailable.localizedDescription)
            return
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentUtterance = utterance
        isSpeaking = true
        // Capture stays active so the controller can recognize an interruption.
        audioLog.notice("Speech playback requested")
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        playbackGeneration += 1
        cloudVoice.stop()
        currentUtterance = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func availableRecognizer() throws -> SFSpeechRecognizer {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw ServiceError.speechPermission
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw ServiceError.microphonePermission
        }
        guard let recognizer, recognizer.isAvailable else { throw ServiceError.recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw ServiceError.onDeviceUnavailable }
        return recognizer
    }

    private func beginRecognition() throws {
        let recognizer = try availableRecognizer()
        guard isRunning, engine.isRunning else { throw ServiceError.microphoneUnavailable }
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        let session = sessionGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextPhrases
        lastTranscript = ""
        sink.replaceRequest(request)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Copy only immutable text/status out of the framework's callback queue.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(session: session, recognition: generation) else { return }
                if let text, !text.isEmpty {
                    if !self.receivedRecognition {
                        self.receivedRecognition = true
                        self.audioLog.notice("On-device recognition produced text")
                    }
                    self.lastTranscript = text
                    self.onPartial?(text, isFinal)
                }
                // The consumer may have stopped or reset us from onPartial.
                guard self.isCurrent(session: session, recognition: generation) else { return }
                if isFinal {
                    self.scheduleRestart(afterError: false)
                } else if failed {
                    self.scheduleRestart(afterError: true)
                }
            }
        }
        rolloverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 50_000_000_000) } catch { return }
            guard let self, self.isCurrent(session: session, recognition: generation) else { return }
            if !self.lastTranscript.isEmpty {
                self.onPartial?(self.lastTranscript, true)
            }
            guard self.isCurrent(session: session, recognition: generation) else { return }
            self.scheduleRestart(afterError: false)
        }
    }

    private func isCurrent(session: UInt64, recognition: UInt64) -> Bool {
        isRunning && sessionGeneration == session && recognitionGeneration == recognition
    }

    private func scheduleRestart(afterError: Bool) {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if afterError {
            recentErrorRestarts.removeAll { now - $0 > 60 }
            guard recentErrorRestarts.count < 3 else {
                fail(ServiceError.repeatedRecognitionFailure.localizedDescription)
                return
            }
            recentErrorRestarts.append(now)
        }
        cancelRecognition()
        let session = sessionGeneration
        let generation = recognitionGeneration
        let delay: UInt64 = afterError ? 500_000_000 : 100_000_000
        restartTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.isCurrent(session: session, recognition: generation) else { return }
            self.restartTask = nil
            do {
                try self.beginRecognition()
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func cancelRecognition() {
        recognitionGeneration &+= 1
        rolloverTask?.cancel()
        rolloverTask = nil
        restartTask?.cancel()
        restartTask = nil
        sink.replaceRequest(nil)
        recognitionTask?.cancel()
        recognitionTask = nil
        lastTranscript = ""
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    private func finishSpeaking(_ utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance else { return }
        currentUtterance = nil
        isSpeaking = false
        audioLog.notice("Speech playback completed")
        onSpeechFinished?()
    }

    private enum ServiceError: LocalizedError {
        case speechPermission, microphonePermission, recognizerUnavailable, onDeviceUnavailable
        case microphoneUnavailable, audioConfigurationChanged, repeatedRecognitionFailure, voiceUnavailable

        var errorDescription: String? {
            switch self {
            case .speechPermission: return "请在系统设置的隐私与安全性中允许语音识别。"
            case .microphonePermission: return "请在系统设置的隐私与安全性中允许麦克风访问。"
            case .recognizerUnavailable: return "中文语音识别当前不可用，请检查系统语音设置后重试。"
            case .onDeviceUnavailable: return "当前设备未提供中文端侧语音识别，已停止监听；不会改用云端识别。"
            case .microphoneUnavailable: return "麦克风不可用，请检查输入设备后重新开启。"
            case .audioConfigurationChanged: return "音频设备已变化，监听已停止，请重新开启。"
            case .repeatedRecognitionFailure: return "端侧语音识别连续失败，监听已停止，请稍后重新开启。"
            case .voiceUnavailable: return "中文朗读声音不可用，请在系统设置中安装中文声音。"
            }
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeaking(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeaking(utterance) }
    }
}

extension SpeechService: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard !available else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, self.recognizer?.isAvailable != true else { return }
            self.fail(ServiceError.recognizerUnavailable.localizedDescription)
        }
    }
}

/// The audio tap runs outside MainActor. A short lock serializes request append/endAudio,
/// and no audio buffer is queued onto the UI actor or retained after the tap returns.
private final class RecognitionAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var lastLevelTime: TimeInterval = 0

    func replaceRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = newRequest
    }

    func consume(_ buffer: AVAudioPCMBuffer) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard let request else { return nil }
        request.append(buffer)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelTime >= 0.1 else { return nil }
        lastLevelTime = now
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        guard rms.isFinite else { return 0 }
        return min(1, rms * 5)
    }
}
