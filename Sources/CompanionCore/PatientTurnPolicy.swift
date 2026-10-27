import Foundation

/// Explicit speech commands, not a semantic end-of-turn classifier.
/// Only final ASR is consumed; ambiguous language keeps the current floor owner.
public struct PatientTurnPolicy: Sendable {
    public private(set) var isHolding = false
    public init() {}

    public mutating func consume(_ transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quoted or interrogative examples must not silently control a live call.
        guard !text.contains(where: { "\"'“”‘’「」『』?？".contains($0) }) else { return }
        let compact = text.filter { !$0.isWhitespace }
        let endings = CharacterSet(charactersIn: "，,。.!！；;、")
        let complete = compact.trimmingCharacters(in: endings)
        let releases: Set<String> = ["你说吧", "我说完了", "可以回答了", "你可以回答了", "好了你说吧", "好了，你说吧", "好了,你说吧"]
        if releases.contains(complete) { isHolding = false; return }
        let first = compact.components(separatedBy: endings).first ?? ""
        let holds: Set<String> = ["等我想一下", "让我想想", "让我想一下", "先听我说", "我没说完", "我还没说完", "我还没有说完"]
        if holds.contains(first) { isHolding = true }
    }
}
