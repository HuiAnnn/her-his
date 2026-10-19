import Foundation

/// Only unambiguous first-person date assertions; everything else goes to the local extractor.
public enum PersonalFacts {
    public static func birthday(from source: String) -> MemoryCandidate? {
        guard !["不对", "说错", "更正", "应该是"].contains(where: source.contains), !MemoryPolicy.preventMemoryStorage(in: source), !MemoryPolicy.isUncertainSource(source) else { return nil }
        let date = #"((?:农历|阴历|公历|阳历)?\s*(?:[12][0-9]{3}年)?\s*(?:[0-9]{1,2}|[一二三四五六七八九十正冬腊]{1,3})月\s*(?:[0-9]{1,2}|[初一二三四五六七八九十廿三]{1,3})(?:日|号)?)"#
        let patterns = [#"^\s*(?:我的生日(?:是|在)?|我出生(?:于|在))\s*"# + date,
                        #"^\s*我是\s*"# + date + #"\s*出生的?"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let fullRange = Range(match.range, in: source), let dateRange = Range(match.range(at: 1), in: source) else { continue }
            let suffix = source[fullRange.upperBound...]
            guard suffix.allSatisfy({ $0.isWhitespace || "。.!！".contains($0) }) else { continue }
            let value = String(source[dateRange]).filter { !$0.isWhitespace }
            guard validDate(value) else { continue }
            return .init(key: "birthday", content: "生日是\(value)", kind: .event, evidence: String(source[fullRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
    private static func number(_ value: String) -> Int? {
        if let n = Int(value) { return n }
        let digit: [Character: Int] = ["一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9,"正":1,"冬":11,"腊":12]
        var text = value
        if text.hasPrefix("初") { text.removeFirst() }
        if text == "十" { return 10 }
        if text == "廿" { return 20 }
        if text.count == 1 { return digit[text.first!] }
        if text.hasPrefix("廿"), text.count == 2, let tail = digit[text.last!] { return 20 + tail }
        let parts = text.split(separator: "十", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count <= 1, parts[1].count <= 1 {
            let tens = parts[0].isEmpty ? 1 : digit[parts[0].first!]
            let units = parts[1].isEmpty ? 0 : digit[parts[1].first!]
            if let tens, let units { return tens * 10 + units }
        }
        return nil
    }
    private static func validDate(_ value: String) -> Bool {
        let lunar = value.hasPrefix("农历") || value.hasPrefix("阴历")
        var clean = value
        for prefix in ["农历", "阴历", "公历", "阳历"] { if clean.hasPrefix(prefix) { clean.removeFirst(prefix.count) } }
        var year: Int?
        if let index = clean.firstIndex(of: "年") { year = Int(clean[..<index]); clean = String(clean[clean.index(after: index)...]) }
        let parts = clean.split(separator: "月")
        guard parts.count == 2, let month = number(String(parts[0])), let day = number(String(parts[1]).replacingOccurrences(of: "日", with: "").replacingOccurrences(of: "号", with: "")), (1...12).contains(month), day > 0 else { return false }
        if lunar { return day <= 30 }
        let y = year ?? 2000
        let leap = y % 400 == 0 || (y % 4 == 0 && y % 100 != 0)
        return day <= [31,leap ? 29 : 28,31,30,31,30,31,31,30,31,30,31][month-1]
    }
}
