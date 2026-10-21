import Foundation
import CompanionCore
import Speech

@main
struct CompanionProbe {
    @MainActor static func main() async {
        let client = OllamaClient(model: "qwen3:4b")
        if CommandLine.arguments.contains("--continuity") { await continuityProbe(client); return }
        if CommandLine.arguments.contains("--quality") { await qualityProbe(client); return }
        if CommandLine.arguments.contains("--memory-only") { await memoryProbe(client); return }
        do {
            let models = try await client.health()
            print("Models: \(models.joined(separator: ", "))")
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            print("Chinese recognizer: available=\(recognizer?.isAvailable ?? false), onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HerHisProbe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try MemoryStore(fileURL: directory.appendingPathComponent("memory.json"), ownerID: "synthetic-test-user")
            var failures: [String] = []
            let samples = ["我一直喜欢晚上散步，白天太吵了。", "他一直不回我，肯定就是不在乎我。", "只想让你听我说，不要给建议。今天工作有点累。"]
            for sample in samples {
                let start = Date()
                let revision = store.revision
                let result = try await client.respond(messages: [ChatMessage(role: "user", content: sample)], memories: store.memories, name: "小禾")
                let applied = try store.apply(candidates: result.memories, source: sample, expectedRevision: revision, enabled: true)
                let record: [String: Any] = ["input": sample, "reply": result.reply, "seconds": Date().timeIntervalSince(start), "candidates": result.memories.map { ["key": $0.key, "content": $0.content, "evidence": $0.evidence] }, "memoryCount": store.memories.count, "applied": applied]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                if sample == samples[0], !store.memories.contains(where: { $0.content.contains("晚") }) {
                    failures.append("明确的散步偏好未自动保存")
                }
            }
            for sample in ["我平时喜欢什么时候散步？", "忘掉我喜欢晚上散步这件事"] {
                let start = Date()
                let result = try await client.respond(messages: [ChatMessage(role: "user", content: sample)], memories: store.memories, name: "小禾")
                let matched = store.memories.filter { result.forgetKeys.contains($0.key) }
                if sample.hasPrefix("忘掉") {
                    if matched.isEmpty { failures.append("自然语言删除未匹配已有偏好") }
                    for memory in matched { try store.delete(id: memory.id) }
                } else if !result.reply.contains("晚") { failures.append("跨轮回忆没有使用已保存偏好") }
                let record: [String: Any] = ["input": sample, "reply": result.reply, "seconds": Date().timeIntervalSince(start), "forgetMatches": matched.count, "remainingMemories": store.memories.count]
                print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
            }
            let before = store.revision
            try store.clear()
            let reloaded = try MemoryStore(fileURL: directory.appendingPathComponent("memory.json"), ownerID: "synthetic-test-user")
            precondition(reloaded.memories.isEmpty && store.revision > before)
            print("Persistence clear/reload: PASS")
            guard failures.isEmpty else { throw ProbeFailure(failures.joined(separator: "；")) }
            print("Automatic memory / recall / forget: PASS")
        } catch {
            fputs("Probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    /// Synthetic local-model evaluation: never reads application history or cloud keys.
    @MainActor private static func continuityProbe(_ client: OllamaClient) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ContinuityProbe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try CallHistoryStore(fileURL: directory.appendingPathComponent("history.json"), ownerID: "synthetic-user")
            let memories = try MemoryStore(fileURL: directory.appendingPathComponent("memory.json"), ownerID: "synthetic-user")
            try store.begin(companion: "小禾", provider: "synthetic", enabled: true)
            try store.append(role: "user", text: "我们编个故事：小舟在做纸船项目，原定周三展示，他有点紧张。")
            try store.append(role: "assistant", text: "小舟在意这次展示。")
            try store.append(role: "user", text: "更正一下，故事里的展示已经改到周五，周三作废。")
            try store.finish()
            let excerpt = ConversationContinuity.prompt(calls: store.calls, companion: "小禾")
            let scenarios = [
                ("resume", "接着上次的故事，小舟正在做什么项目？", excerpt, "应提到纸船项目，不虚构后续经过"),
                ("correction", "上次故事里的展示最后定在哪天？", excerpt, "应回答周五，不把周三当最终日期"),
                ("no_context", "上次故事里的展示最后定在哪天？", "", "应承认缺少背景，不编造日期")
            ]
            for (scenario, query, context, expected) in scenarios {
                let start = Date()
                let reply = try await client.respond(messages: [.init(role: "user", content: query)], memories: [], name: "小禾", continuity: context)
                try memories.apply(candidates: reply.memories, source: query, expectedRevision: memories.revision, enabled: true)
                guard memories.memories.isEmpty else { throw ProbeFailure("旧故事被错误写成当前用户事实") }
                let record: [String: Any] = ["storedMemories": memories.memories.count, "scenario": scenario, "query": query, "expected": expected, "reply": reply.reply,
                                           "seconds": Date().timeIntervalSince(start), "memoryCandidates": reply.memories.count]
                print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
            }
            print("Synthetic local responses collected; judge against expected text. Not a cloud audio or listening-quality pass.")
        } catch { fputs("Continuity probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor private static func qualityProbe(_ client: OllamaClient) async {
        do {
            for source in ["你知道怎么做饭吗？", "我喜欢什么饮料？", "我喜欢晚上散步，有什么路线推荐？", "今天好累啊"] {
                let candidates = try await client.memoryCandidates(source: source, existing: [])
                if source.contains("晚上散步") {
                    guard candidates.contains(where: { $0.content.contains("散步") }) else { throw ProbeFailure("混合句中的明确偏好遗漏") }
                } else if !candidates.isEmpty { throw ProbeFailure("普通提问或单次疲惫被提取") }
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["kind": "memory", "source": source, "candidates": candidates.map(\.content)], options: [.sortedKeys]), as: UTF8.self))
            }
            let scenarios: [(String, [ChatMessage])] = [
                ("listen", [.init(role: "user", content: "先听我说，不要给建议。今天被老板批评了。"), .init(role: "assistant", content: "被当面批评，确实不好受。"), .init(role: "user", content: "我已经很努力了，可还是被否定。")]),
                ("disagree", [.init(role: "user", content: "朋友半天没回消息，所有人肯定都讨厌我。")]),
                ("advice", [.init(role: "user", content: "明天要汇报，我很紧张。给我一个现在能做的小建议。")]),
                ("quiet", [.init(role: "user", content: "我先忙一会，你安静陪我就行。")])
            ]
            for (name, messages) in scenarios {
                let result = try await client.respond(messages: messages, memories: [], name: "小禾")
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["kind": "tone", "scenario": name, "source": messages.map(\.content), "reply": result.reply], options: [.sortedKeys]), as: UTF8.self))
            }
        } catch { fputs("Quality probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor private static func memoryProbe(_ client: OllamaClient) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HerHisMemoryProbe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try MemoryStore(fileURL: directory.appendingPathComponent("memory.json"), ownerID: "synthetic-test-user")
            for source in ["我出生于1995年6月18日。", "我的生日是农历八月初三", "我一直喜欢晚上散步，白天太吵了。", "生日会保存到慢慢记得里面吗？"] {
                let start = Date(), before = store.memories.count
                let candidates = try await client.memoryCandidates(source: source, existing: store.memories)
                _ = try store.apply(candidates: candidates, source: source, expectedRevision: store.revision, enabled: true)
                if source.contains("慢慢记得") { guard candidates.isEmpty, store.memories.count == before else { throw ProbeFailure("误保存操作旁白") } }
                else { guard !candidates.isEmpty else { throw ProbeFailure("明确事实或偏好未提取") } }
                print("Synthetic memory: \(source) -> \(candidates.map(\.content)), \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            }
            let restored = try MemoryStore(fileURL: directory.appendingPathComponent("memory.json"), ownerID: "synthetic-test-user")
            guard restored.memories.contains(where: { $0.key == "birthday" && $0.content == "生日是农历八月初三" }) else { throw ProbeFailure("生日持久化失败") }
            print("Local automatic memory / persistence / meta rejection: PASS (synthetic data only)")
        } catch { fputs("Memory probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }

}

private struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
