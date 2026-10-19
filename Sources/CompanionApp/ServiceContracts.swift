import Foundation
import CompanionCore

@MainActor protocol SpeechDriving: AnyObject {
    var onPartial: ((String, Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onPlaybackFailure: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onSpeechFinished: (() -> Void)? { get set }
    var contextPhrases: [String] { get set }
    var isRunning: Bool { get }
    var isSpeaking: Bool { get }
    func requestPermission() async throws
    func start() throws
    func stop()
    func resetRecognition() throws
    func speak(_ text: String)
    func stopSpeaking()
}

@MainActor protocol ModelServing {
    func memoryCandidates(source: String, existing: [CompanionMemory]) async throws -> [MemoryCandidate]
    func health() async throws -> [String]
    func respond(messages: [ChatMessage], memories: [CompanionMemory], name: String) async throws -> ModelReply
}
extension SpeechService: SpeechDriving {}
extension OllamaClient: ModelServing {}

extension ModelServing {
    func memoryCandidates(source: String, existing: [CompanionMemory]) async throws -> [MemoryCandidate] { throw ModelClientError.invalidResponse }
}
