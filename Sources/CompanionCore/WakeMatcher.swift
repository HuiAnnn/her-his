import Foundation

public enum WakeMatcher {
    /// Only a leading address wakes the companion. An empty remainder is a name-only call.
    public static func remainder(in input: String, name: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let range = text.range(of: name, options: [.anchored, .caseInsensitive]) else { return nil }
        let tail = text[range.upperBound...]
        if name.unicodeScalars.last.map({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) == true,
           let next = tail.unicodeScalars.first, CharacterSet.alphanumerics.contains(next) { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return String(tail).trimmingCharacters(in: separators)
    }
}
