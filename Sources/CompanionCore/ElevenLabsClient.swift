import Foundation

public enum CloudVoiceError: Error, LocalizedError, Equatable {
    case missingKey, missingVoice, invalidResponse, authentication, quota, unavailable, keychain
    public var errorDescription: String? {
        switch self {
        case .missingKey: return "请先在相处设置中保存 ElevenLabs API Key。"
        case .missingVoice: return "请先选择声线和语音模型。"
        case .invalidResponse: return "语音服务没有返回可播放的音频或有效列表，请稍后重试。"
        case .authentication: return "语音服务拒绝了请求，请检查 API Key、接口权限及声线访问权限。"
        case .quota: return "语音额度不足或请求过于频繁，请检查 ElevenLabs 账户后重试。"
        case .unavailable: return "云端语音暂时无法连接，请检查网络后重试。文字回复仍可查看。"
        case .keychain: return "无法访问 macOS 钥匙串，密钥没有被保存或读取，请检查系统授权。"
        }
    }
}

public struct CloudVoice: Decodable, Identifiable, Sendable {
    public let voiceID: String
    public let name: String
    public let labels: [String: String]?
    public var id: String { voiceID }
    enum CodingKeys: String, CodingKey { case voiceID = "voice_id", name, labels }
}

public struct CloudVoiceModel: Decodable, Identifiable, Sendable {
    public let modelID: String
    public let name: String?
    public let canDoTextToSpeech: Bool?
    public let languages: [Language]?
    public var id: String { modelID }
    public struct Language: Decodable, Sendable {
        public let languageID: String
        enum CodingKeys: String, CodingKey { case languageID = "language_id" }
    }
    enum CodingKeys: String, CodingKey {
        case modelID = "model_id", name, canDoTextToSpeech = "can_do_text_to_speech", languages
    }
}

/// No conversation history, microphone data, or memory database is sent by this client.
public struct ElevenLabsClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport

    public init(transport: @escaping Transport = { try await ElevenLabsClient.liveTransport($0) }) { self.transport = transport }

    public func synthesize(_ text: String, key: String, voiceID: String, modelID: String) async throws -> Data {
        guard Self.validIdentifier(voiceID), Self.validIdentifier(modelID) else { throw CloudVoiceError.missingVoice }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudVoiceError.invalidResponse }
        var request = try request(path: "/v1/text-to-speech/\(voiceID)", key: key,
                                  query: [URLQueryItem(name: "output_format", value: "mp3_44100_128")])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": modelID])
        let (data, response) = try await send(request)
        guard !data.isEmpty, data.count <= 20_000_000,
              response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("audio/") == true
        else { throw CloudVoiceError.invalidResponse }
        return data
    }

    public func voices(key: String) async throws -> [CloudVoice] {
        struct Page: Decodable {
            let voices: [CloudVoice]
            let has_more: Bool
            let next_page_token: String?
        }
        var result: [CloudVoice] = [], seen: Set<String> = []
        var token: String?
        for _ in 0..<100 {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let token { query.append(URLQueryItem(name: "next_page_token", value: token)) }
            let (data, _) = try await send(request(path: "/v2/voices", key: key, query: query))
            let page: Page = try decode(data)
            result.append(contentsOf: page.voices)
            if !page.has_more { return result }
            guard let next = page.next_page_token, !next.isEmpty, seen.insert(next).inserted else { throw CloudVoiceError.invalidResponse }
            token = next
        }
        throw CloudVoiceError.invalidResponse
    }

    public func models(key: String) async throws -> [CloudVoiceModel] {
        let (data, _) = try await send(request(path: "/v1/models", key: key))
        let models: [CloudVoiceModel] = try decode(data)
        return models.filter { $0.canDoTextToSpeech == true && $0.languages?.contains(where: { $0.languageID == "zh" }) == true }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CloudVoiceError.invalidResponse }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private func request(path: String, key: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw CloudVoiceError.missingKey }
        var components = URLComponents()
        components.scheme = "https"; components.host = "api.elevenlabs.io"; components.path = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let result = try await transport(request)
            try Task.checkCancellation()
            switch result.1.statusCode {
            case 200..<300: return result
            case 401, 403: throw CloudVoiceError.authentication
            case 402, 429: throw CloudVoiceError.quota
            default: throw CloudVoiceError.unavailable
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CloudVoiceError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw CloudVoiceError.unavailable }
    }

    public static func liveTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoVoiceRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudVoiceError.invalidResponse }
        return (data, response)
    }
}

/// Never forward an API key or a reply body to another endpoint on redirect.
private final class NoVoiceRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
