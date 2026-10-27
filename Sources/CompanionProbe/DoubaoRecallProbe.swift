import Foundation
import Security
import LocalAuthentication
import AVFoundation
import CompanionCore

/// Explicit developer evaluation: synthetic input only, no microphone or private history.
enum DoubaoRecallProbe {
    static func run() async {
        do {
            let auth = LAContext(); auth.interactionNotAllowed = true
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.huian.herhis.doubao", kSecAttrAccount as String: "api-key",
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: auth]
            var found: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            guard status == errSecSuccess, let data = found as? Data else {
                throw Failure("凭证无法无交互读取；未请求密码或发起云端请求。")
            }
            let credential = try JSONDecoder().decode(DoubaoCredentials.self, from: data)
            if CommandLine.arguments.contains("--patient-timing") {
                try await DoubaoTimingProbe.run(credential)
                return
            }
            let repetitions = CommandLine.arguments.contains("--repeat-three") ? 3 : 1
            for repetition in 1...repetitions {
                try await episode(credential, repetition: repetition)
            }
            print("Synthetic cloud evaluation completed. Review every reply; this is not a microphone/listening-quality pass.")
        } catch {
            // Never print provider payloads or credential-containing requests.
            fputs("Doubao recall evaluation failed: \((error as? Failure)?.message ?? "连接、协议或授权失败；未输出凭证。")\n", stderr)
            exit(1)
        }
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    private static func episode(_ credential: DoubaoCredentials, repetition: Int) async throws {
        let known = CommandLine.arguments.contains("--known-context")
        let context = known ? try await knownContext() : ""
        let config = RealtimeConfiguration(name: "测试伙伴", model: "1.2.1.1", voice: "zh_female_vv_jupiter_bigtts", memoryEnabled: false, continuity: context)
        let transport = URLSession(configuration: .ephemeral)
        let socket = transport.webSocketTask(with: try credential.request())
        socket.maximumMessageSize = 1_048_800
        let id = UUID().uuidString
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); transport.invalidateAndCancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 90_000_000_000)
                socket.cancel(with: .goingAway, reason: nil)
                throw Failure("合成试聊超时。")
            }
            group.addTask {
                func send(_ event: Int, _ body: [String: Any] = [:]) async throws {
                    let data = try DoubaoPacket.encode(event: event, sessionID: event >= 100 ? id : nil,
                                                      payload: JSONSerialization.data(withJSONObject: body))
                    try await socket.send(.data(data))
                }
                func receive() async throws -> DoubaoPacket {
                    guard case let .data(data) = try await socket.receive() else { throw Failure("服务返回非二进制包。") }
                    let packet = try DoubaoPacket.decode(data)
                    if CommandLine.arguments.contains("--trace-events"), packet.event != 352 {
                        print("event=\(packet.event)"); fflush(stdout)
                    }
                    return packet
                }
                try await send(1)
                while try await receive().event != 50 {}
                try await send(100, DoubaoPacket.session(config))
                while try await receive().event != 150 {}
                let turns = ["之前让你编的那个故事还记得吗？", "你说一下那故事。", "那就重新编一个关于灯塔的短故事吧。"]
                for (index, text) in turns.enumerated() {
                    let arguments = CommandLine.arguments
                    let audioIndex = arguments.firstIndex(of: "--synthetic-audio-directory")
                    if let audioIndex, audioIndex + 1 < arguments.count {
                        let url = URL(fileURLWithPath: arguments[audioIndex + 1]).appendingPathComponent("\(index + 1).wav")
                        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
                        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                              file.length > 0, file.length < 16000 * 30,
                              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw Failure("仅接受30秒内16k单声道合成WAV。") }
                        try file.read(into: buffer)
                        guard let samples = buffer.int16ChannelData?[0] else { throw Failure("合成音频格式不正确。") }
                        var pcm = Data(bytes: samples, count: Int(buffer.frameLength) * 2)
                        pcm.append(Data(repeating: 0, count: 16000 * 2 * 4))
                        for start in stride(from: 0, to: pcm.count, by: 640) {
                            try await socket.send(.data(DoubaoPacket.encode(event: 200, sessionID: id,
                                payload: pcm.subdata(in: start..<min(start + 640, pcm.count)), audio: true)))
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                    } else { try await send(501, ["content": text]) }
                    var caption = "", fallback = "", transcript = ""
                    while true {
                        let packet = try await receive()
                        let body = (try? JSONSerialization.jsonObject(with: packet.payload)) as? [String: Any] ?? [:]
                        if packet.event == 550 { caption += body["content"] as? String ?? "" }
                        if packet.event == 350 { fallback += body["text"] as? String ?? "" }
                        if packet.event == 451, let results = body["results"] as? [[String: Any]], let last = results.last { transcript = last["text"] as? String ?? "" }
                        if [51, 52, 152, 153, 599].contains(packet.event) { throw Failure("服务结束了合成试聊。") }
                        if packet.event == 359 { break }
                    }
                    let record: [String: Any] = ["repetition": repetition, "turn": index + 1, "query": text,
                        "reply": caption.isEmpty ? fallback : caption, "inputMode": audioIndex == nil ? "text" : "synthetic-audio", "transcript": transcript,
                        "knownContext": known,
                        "expected": index < 2 ? (known ? "只复述已有的小舟纸船故事，最终周五，不捏造细节" : "无旧故事证据，应明确没有内容，不能含糊声称记得或编旧故事") : "明确新创作请求，可以讲新的灯塔故事"]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
                    fflush(stdout)
                }
                try await send(102)
            }
            _ = try await group.next(); group.cancelAll()
        }
    }
    @MainActor private static func knownContext() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticRecall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try CallHistoryStore(fileURL: folder.appendingPathComponent("history.json"), ownerID: "synthetic-user")
        try store.begin(companion: "测试伙伴", provider: "synthetic", enabled: true)
        try store.append(role: "user", text: "我们编了一个故事：小舟在准备纸船展示，原定周三，后来改到周五。")
        try store.finish()
        return ConversationContinuity.prompt(calls: store.calls, companion: "测试伙伴")
    }
}
