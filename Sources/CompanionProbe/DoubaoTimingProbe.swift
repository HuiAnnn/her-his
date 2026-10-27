import Foundation
import AVFoundation
import CompanionCore

/// Synthetic PCM only. Measures server events, not microphone acoustics or playback latency.
enum DoubaoTimingProbe {
    private struct Failure: Error {}
    static func run(_ credentials: DoubaoCredentials) async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--synthetic-audio-directory"), index + 1 < CommandLine.arguments.count else { throw Failure() }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        func read(_ name: String) throws -> Data {
            let file = try AVAudioFile(forReading: directory.appendingPathComponent(name), commonFormat: .pcmFormatInt16, interleaved: false)
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length > 0, file.length < 16000 * 20,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw Failure() }
            try file.read(into: buffer)
            guard let samples = buffer.int16ChannelData?[0] else { throw Failure() }
            return Data(bytes: samples, count: Int(buffer.frameLength) * 2)
        }
        let first = try read("1.wav"), second = try read("2.wav")
        for window in [1500, 3000] {
            try await measure(credentials, first: first, second: second, window: window)
        }
    }
    private static func measure(_ credentials: DoubaoCredentials, first: Data, second: Data, window: Int) async throws {
        let transport = URLSession(configuration: .ephemeral)
        let socket = transport.webSocketTask(with: try credentials.request())
        socket.maximumMessageSize = 1_048_800; socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); transport.invalidateAndCancel() }
        let sessionID = UUID().uuidString
        func send(_ event: Int, _ body: [String: Any] = [:]) async throws {
            try await socket.send(.data(DoubaoPacket.encode(event: event, sessionID: event >= 100 ? sessionID : nil, payload: JSONSerialization.data(withJSONObject: body))))
        }
        @Sendable func receive() async throws -> DoubaoPacket {
            guard case let .data(bytes) = try await socket.receive() else { throw Failure() }
            let packet = try DoubaoPacket.decode(bytes)
            if [51, 52, 152, 153, 599].contains(packet.event) { throw Failure() }
            return packet
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                socket.cancel(with: .goingAway, reason: nil); throw Failure()
            }
            group.addTask {
                try await send(1)
                while try await receive().event != 50 {}
                var config = try DoubaoPacket.session(.init(name: "测试伙伴", model: "1.2.1.1", voice: "zh_female_vv_jupiter_bigtts", memoryEnabled: false))
                config["asr"] = ["extra": ["end_smooth_window_ms": window, "enable_custom_vad": true]]
                try await send(100, config)
                while try await receive().event != 150 {}
                let origin = ProcessInfo.processInfo.systemUptime
                // Concurrent receiver observes arrival time, not when queued events are drained.
                async let observed: [(Int, Double, String)] = {
                    var events: [(Int, Double, String)] = []
                    var started = Set<Int>()
                    while true {
                        let packet = try await receive()
                        let body = (try? JSONSerialization.jsonObject(with: packet.payload)) as? [String: Any] ?? [:]
                        if [450, 459, 350, 359].contains(packet.event) || (packet.event == 352 && started.insert(352).inserted) {
                            events.append((packet.event, ProcessInfo.processInfo.systemUptime - origin, ""))
                        }
                        if packet.event == 451, let results = body["results"] as? [[String: Any]], let last = results.last, last["is_interim"] as? Bool == false {
                            events.append((451, ProcessInfo.processInfo.systemUptime - origin, last["text"] as? String ?? ""))
                        }
                        // Stop after a response to the complete synthetic sample; bound by timeout.
                        if packet.event == 359, ProcessInfo.processInfo.systemUptime - origin > Double(first.count + second.count) / 32000 + 2 { return events }
                    }
                }()
                func stream(_ data: Data) async throws {
                    let clock = ContinuousClock(), started = ContinuousClock.now
                    for offset in stride(from: 0, to: data.count, by: 640) {
                        try await socket.send(.data(DoubaoPacket.encode(event: 200, sessionID: sessionID, payload: data.subdata(in: offset..<min(offset + 640, data.count)), audio: true)))
                        try await Task.sleep(until: started.advanced(by: .milliseconds((offset / 640 + 1) * 20)), tolerance: .milliseconds(1), clock: clock)
                    }
                }
                try await stream(first)
                let pauseBegan = ProcessInfo.processInfo.systemUptime - origin
                try await stream(Data(repeating: 0, count: 32000 * 2))
                let resumed = ProcessInfo.processInfo.systemUptime - origin
                try await stream(second)
                let speechEnded = ProcessInfo.processInfo.systemUptime - origin
                try await stream(Data(repeating: 0, count: 32000 * 5))
                let events = try await observed
                let firstAudio = events.first { $0.0 == 352 }?.1
                let result: [String: Any] = ["windowMs": window, "pauseBeganSeconds": pauseBegan, "resumedSeconds": resumed,
                    "speechEndedSeconds": speechEnded, "firstAudioSeconds": firstAudio as Any? ?? NSNull(),
                    "respondedBeforeResumed": firstAudio.map { $0 < resumed } ?? false,
                    "events": events.map { ["event": $0.0, "seconds": $0.1, "syntheticTranscript": $0.2] as [String: Any] }]
                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout)
                try await send(102)
            }
            _ = try await group.next(); group.cancelAll()
        }
    }
}
