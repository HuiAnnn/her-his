import XCTest
@testable import CompanionCore

private final class ModelTransport: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var responseDelay: ((URLRequest) -> TimeInterval)?
    static var onDelayedCancellation: (() -> Void)?
    private var pendingDelivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let delay = Self.responseDelay?(request) ?? 0
            if delay > 0 {
                let delivery = DispatchWorkItem { [weak self] in self?.deliver(status: status, data: data) }
                pendingDelivery = delivery
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: delivery)
            } else { deliver(status: status, data: data) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func deliver(status: Int, data: Data) {
        guard pendingDelivery?.isCancelled != true else { return }
        pendingDelivery = nil
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if let pendingDelivery { pendingDelivery.cancel(); Self.onDelayedCancellation?() }
    }
}

final class ModelClientTests: XCTestCase {
    private func client(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "qwen3:4b") -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelTransport.self]
        return OllamaClient(baseURL: baseURL, model: model, session: URLSession(configuration: configuration))
    }
    private func envelope(_ content: String, done: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": "qwen3:4b", "message": ["role": "assistant", "content": content], "done": done, "done_reason": "stop"])
    }
    private let validJSON = #"{"reply":"我在，慢慢说。","memories":[],"forgetKeys":[],"endConversation":false}"#

    func testBackgroundMemoryHasIndependentBudgetAndRejectsStorageNarration() async throws {
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            XCTAssertEqual(request.timeoutInterval, 30)
            let content = #"{"memories":[{"key":"birthday_reminder","content":"希望记录生日","kind":"event","evidence":"生日会保存到慢慢记得里面"}]}"#
            return (200, try self.envelope(content))
        }
        let candidates = try await client().memoryCandidates(source: "生日会保存到慢慢记得里面", existing: [])
        XCTAssertTrue(candidates.isEmpty)
    }
    func testRequestIsLocalStructuredNonStreamingAndReplyParses() async throws {
        let response = try envelope(validJSON)
        var paths: [String] = []
        ModelTransport.handler = { request in
            paths.append(request.url!.path)
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096); var collected = Data()
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; collected.append(bytes, count: count) }
                data = collected
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "qwen3:4b")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["think"] as? Bool, false)
            XCTAssertNotNil(body["format"] as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.first?["role"], "system")
            XCTAssertTrue(messages.first?["content"]?.contains("合成的过去通话背景") == true)
            XCTAssertEqual(messages.last?["content"], "你好\n/no_think")
            XCTAssertTrue(messages.contains { ($0["content"] ?? "").contains("/no_think") })
            return (200, response)
        }
        let result = try await client().respond(messages: [.init(role: "user", content: "你好")], memories: [], name: "小禾", continuity: "合成的过去通话背景")
        XCTAssertEqual(paths, ["/api/show", "/api/chat"])
        XCTAssertEqual(result.reply, "我在，慢慢说。")
        XCTAssertTrue(result.memories.isEmpty)
    }
    func testForgetKeysSurviveUnverifiedModelAcknowledgement() async throws {
        let response = try envelope(#"{"reply":"已经删除了。","memories":[],"forgetKeys":["walking"],"endConversation":false}"#)
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            return (200, response)
        }
        let result = try await client().respond(messages: [.init(role: "user", content: "忘掉我的散步偏好")], memories: [], name: "小禾")
        XCTAssertEqual(result.forgetKeys, ["walking"])
        XCTAssertFalse(result.reply.contains("已"))
    }
    func testHealthListsInstalledModels() async throws {
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            XCTAssertEqual(request.url?.path, "/api/tags")
            return (200, Data(#"{"models":[{"name":"qwen3:4b"},{"name":"other:latest"}]}"#.utf8))
        }
        let names = try await client().health()
        XCTAssertEqual(names, ["qwen3:4b", "other:latest"])
    }
    func testRemoteAndCredentialEndpointsRejectedBeforeTransport() async {
        ModelTransport.handler = { _ in XCTFail("Must not send to an unsafe endpoint"); return (200, Data()) }
        for value in ["https://example.com", "http://localhost.example.com:11434", "http://user:secret@localhost:11434", "file:///tmp/model", "http://127.0.0.2:11434", "http://localhost:11434/path"] {
            do { _ = try await client(baseURL: URL(string: value)!).health(); XCTFail(value) }
            catch { XCTAssertTrue(error is ModelClientError, "\(error)") }
        }
    }
    func testRejectsMalformedTruncatedOversizedAndReasoningResponses() async throws {
        for content in ["plain text", #"{"reply":"hello"}"#, validJSON + " trailing", #"{"reply":"<think>reasoning</think>","memories":[],"forgetKeys":[],"endConversation":false}"#, #"{"reply":"","memories":[],"forgetKeys":[],"endConversation":false}"#] {
            let response = try envelope(content)
            ModelTransport.handler = { request in
                if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
                return (200, response)
            }
            do { _ = try await client().respond(messages: [.init(role: "user", content: "你好")], memories: [], name: "小禾"); XCTFail(content) }
            catch { XCTAssertTrue(error is ModelClientError) }
        }
        let unfinished = try envelope(validJSON, done: false)
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            return (200, unfinished)
        }
        do { _ = try await client().respond(messages: [.init(role: "user", content: "你好")], memories: [], name: "小禾"); XCTFail("Truncated response accepted") } catch { XCTAssertTrue(error is ModelClientError) }
        ModelTransport.handler = { _ in (200, Data(repeating: 32, count: 70_000)) }
        do { _ = try await client().health(); XCTFail("Oversized response accepted") } catch { XCTAssertTrue(error is ModelClientError) }
    }
    func testHTTPErrorsAreHonestAndDoNotTurnIntoCompanionReplies() async {
        ModelTransport.handler = { _ in (404, Data(#"{"error":"model not found"}"#.utf8)) }
        do { _ = try await client().respond(messages: [.init(role: "user", content: "你好")], memories: [], name: "小禾"); XCTFail("HTTP failure accepted") }
        catch { XCTAssertTrue(error is ModelClientError) }
    }
    func testListenOnlyPreservesActualEmpathyAndRemovesMemoryInvitation() throws {
        let input = "只想让你听我说，不要给建议。今天工作有点累。"
        let actualModelOutput = "小禾在这里，听你讲今天工作累的事。需要我帮你记录一下吗？"
        XCTAssertEqual(try ReplyPolicy.enforce(actualModelOutput, for: input), "小禾在这里，听你讲今天工作累的事。")
        XCTAssertEqual(try ReplyPolicy.enforce("听起来今天很累。我们来做个呼吸练习。", for: input), "听起来今天很累。")
        XCTAssertEqual(try ReplyPolicy.enforce("That sounds tiring. Would you like me to help?", for: "Just listen, no advice please."), "That sounds tiring.")
    }
    func testListenOnlyRejectsOnlyQuestionsOrHelpWithoutInventingFallback() {
        for output in ["需要我帮你一起放松一下吗？", "要不要我帮你记录一下", "不如试试深呼吸。", "你应该早点休息。", "我可以帮你整理情绪。"] {
            XCTAssertThrowsError(try ReplyPolicy.enforce(output, for: "不要给建议，听我说就好。"), output) { error in
                guard case ModelClientError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }
    func testOrdinaryConversationQuestionAndUserRequestedAdviceStayUnchanged() throws {
        let question = "今天最累的是什么？需要我帮你一起想想吗？"
        XCTAssertEqual(try ReplyPolicy.enforce(question, for: "今天工作有点累。"), question)
        XCTAssertEqual(try ReplyPolicy.enforce("你可以先休息一下。", for: "你有什么建议？"), "你可以先休息一下。")
        XCTAssertEqual(try ReplyPolicy.enforce("我在听。", for: "不要给建议。"), "我在听。")
    }
    func testClientEnforcesListenOnlyBeforeReturningModelReply() async throws {
        let response = try envelope(#"{"reply":"小禾在这里，听你讲今天工作累的事。需要我帮你记录一下吗？","memories":[],"forgetKeys":[],"endConversation":false}"#)
        ModelTransport.handler = { request in
                if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
                return (200, response)
            }
        let result = try await client().respond(messages: [.init(role: "user", content: "只想让你听我说，不要给建议。今天工作有点累。")], memories: [], name: "小禾")
        XCTAssertEqual(result.reply, "小禾在这里，听你讲今天工作累的事。")
        XCTAssertTrue(result.memories.isEmpty)
    }

    func testRejectsCloudNamesAndCloudAliasesBeforeSendingConversation() async throws {
        let response = try envelope(validJSON)
        for (model, metadata) in [
            ("qwen3:cloud", #"{"details":{"format":"gguf"}}"#),
            ("qwen3-cloud:latest", #"{"details":{"format":"gguf"}}"#),
            ("local-alias", #"{"details":{"format":"gguf"},"remote_host":"https://ollama.com"}"#),
            ("local-alias", #"{"details":{"format":"gguf"},"remote_model":"remote-large"}"#),
            ("local-alias", #"{"details":{"format":"unknown"}}"#),
            ("local-alias", #"{}"#)
        ] {
            var sentConversation = false
            ModelTransport.handler = { request in
                if request.url?.path == "/api/show" { return (200, Data(metadata.utf8)) }
                sentConversation = true
                return (200, response)
            }
            do { _ = try await client(model: model).respond(messages: [.init(role: "user", content: "Synthetic private utterance")], memories: [], name: "小禾"); XCTFail("Unverified model accepted: \(model), \(metadata)") }
            catch { XCTAssertTrue(error is ModelClientError) }
            XCTAssertFalse(sentConversation, "Conversation reached chat without local-model verification")
        }
    }
    func testHealthOmitsCloudAndUnverifiedCandidates() async throws {
        var shows = 0
        ModelTransport.handler = { request in
            if request.url?.path == "/api/tags" {
                return (200, Data(#"{"models":[{"name":"qwen3:4b"},{"name":"remote-alias"},{"name":"large:cloud"}]}"#.utf8))
            }
            shows += 1
            if shows == 1 { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            return (200, Data(#"{"details":{"format":"gguf"},"remote_model":"large"}"#.utf8))
        }
        let models = try await client().health()
        XCTAssertEqual(models, ["qwen3:4b"])
        XCTAssertEqual(shows, 2)
    }

    func testAutomaticMemoryNeverSolicitsPerItemSavingOrClaimsUnverifiedActions() throws {
        let actual = "我理解你晚上散步的偏好，白天噪音确实影响休息。需要我帮你记录这个习惯吗？"
        XCTAssertEqual(try ReplyPolicy.enforce(actual, for: "我一直喜欢晚上散步，白天太吵了。"), "我理解你晚上散步的偏好，白天噪音确实影响休息。")
        for claim in ["要我记住这个习惯吗？", "我会记住你的偏好。", "已经保存了。", "我已经删除这条记忆了。"] {
            XCTAssertThrowsError(try ReplyPolicy.enforce(claim, for: "我喜欢散步。"), claim)
        }
        let recall = "我记得你喜欢晚上散步。今天最累的是什么？"
        XCTAssertEqual(try ReplyPolicy.enforce(recall, for: "今天工作有点累。"), recall)
    }
    func testListenOnlyRemovesRequestsForFurtherEmotionalDetails() throws {
        let actual = "好，我认真听。今天工作累，可以多说说具体感受。"
        XCTAssertEqual(try ReplyPolicy.enforce(actual, for: "只想让你听我说，不要给建议。今天工作有点累。"), "好，我认真听。")
        XCTAssertEqual(try ReplyPolicy.enforce("我在。说说具体发生了什么。聊聊具体感受吧。", for: "听我说就好。"), "我在。")
    }

    func testListenOnlyPersistsUntilExplicitAdviceRequestAndResetsWithNewHistory() throws {
        var history = [ChatMessage(role: "user", content: "只想让你听，不要给建议。"), ChatMessage(role: "assistant", content: "我在听。"), ChatMessage(role: "user", content: "今天又加班。")]
        let reply = "这一天很辛苦。需要我帮你想办法吗？"
        XCTAssertEqual(try ReplyPolicy.enforce(reply, messages: history), "这一天很辛苦。")
        history.append(ChatMessage(role: "user", content: "现在可以给我建议了。"))
        XCTAssertEqual(try ReplyPolicy.enforce(reply, messages: history), reply)
        history.append(ChatMessage(role: "user", content: "不可以给我建议，听着就好。"))
        XCTAssertEqual(try ReplyPolicy.enforce(reply, messages: history), "这一天很辛苦。")
        XCTAssertEqual(try ReplyPolicy.enforce(reply, messages: [.init(role: "user", content: "今天又加班。")]), reply)
    }
    func testClientKeepsExplicitListeningModeAcrossUnspecifiedFollowUp() async throws {
        let response = try envelope(#"{"reply":"又加班很累。可以多说说具体感受。","memories":[],"forgetKeys":[],"endConversation":false}"#)
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            return (200, response)
        }
        let result = try await client().respond(messages: [.init(role: "user", content: "只想让你听，不要给建议。"), .init(role: "assistant", content: "我在听。"), .init(role: "user", content: "今天又加班。")], memories: [], name: "小禾")
        XCTAssertEqual(result.reply, "又加班很累。")
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096); var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                collected.append(bytes, count: count)
            }
            data = collected
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }
    func testEmptyMemoryFallbackExtractsCurrentStatementAndReverifiesLocalModel() async throws {
        let source = "我一直喜欢晚上散步，白天太吵了。"
        let first = try envelope(validJSON)
        let second = try envelope(#"{"memories":[{"key":"walking_time","content":"喜欢晚上散步，觉得白天太吵","kind":"preference","evidence":"我一直喜欢晚上散步，白天太吵了"}]}"#)
        var paths: [String] = []; var chats = 0
        ModelTransport.handler = { request in
            paths.append(request.url!.path)
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            chats += 1
            if chats == 1 { return (200, first) }
            let body = try self.requestObject(request)
            let options = try XCTUnwrap(body["options"] as? [String: Any])
            XCTAssertEqual(options["temperature"] as? Int, 0)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertTrue(messages[1]["content"]!.contains(source))
            XCTAssertFalse(messages[1]["content"]!.contains("我喜欢咖啡"))
            XCTAssertTrue(messages[1]["content"]!.contains("walking_time"))
            let format = try XCTUnwrap(body["format"] as? [String: Any])
            XCTAssertEqual(format["required"] as? [String], ["memories"])
            return (200, second)
        }
        let result = try await client().respond(messages: [.init(role: "user", content: "我喜欢咖啡"), .init(role: "assistant", content: "嗯。"), .init(role: "user", content: source)], memories: [.init(key: "walking_time", content: "以前喜欢下午散步", kind: .preference)], name: "小禾")
        XCTAssertEqual(paths, ["/api/show", "/api/chat", "/api/show", "/api/chat"])
        XCTAssertEqual(result.reply, "我在，慢慢说。")
        XCTAssertEqual(result.memories.first?.key, "walking_time")
        XCTAssertEqual(result.memories.first?.evidence, "我一直喜欢晚上散步，白天太吵了")
        XCTAssertNil(result.memoryIssue)
    }
    func testFallbackSkipsPrivateUncertainCredentialQuestionsAndOrdinaryTurns() async throws {
        let first = try envelope(validJSON)
        for source in ["今天有点累。", "我喜欢散步，但不要记住。", "假如我喜欢散步。", "朋友说我喜欢散步。", "我喜欢的密码是abc。", "我平时喜欢什么时候散步？", "我喜欢散步吗", "我喜欢散步，我不确定。"] {
            var chats = 0
            ModelTransport.handler = { request in
                if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
                chats += 1; return (200, first)
            }
            let result = try await client().respond(messages: [.init(role: "user", content: source)], memories: [], name: "小禾")
            XCTAssertEqual(chats, 1, source)
            XCTAssertTrue(result.memories.isEmpty)
        }
    }
    func testFallbackDoesNotRepeatWhenMainResponseAlreadyContainsMemory() async throws {
        let first = try envelope(#"{"reply":"晚上走走挺舒服。","memories":[{"key":"walking_time","content":"喜欢晚上散步","kind":"preference","evidence":"我喜欢晚上散步"}],"forgetKeys":[],"endConversation":false}"#)
        var chats = 0
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            chats += 1; return (200, first)
        }
        let result = try await client().respond(messages: [.init(role: "user", content: "我喜欢晚上散步。")], memories: [], name: "小禾")
        XCTAssertEqual(chats, 1)
        XCTAssertEqual(result.memories.count, 1)
    }
    func testFallbackRejectsUnsupportedEvidenceAndReportsFailureWithoutLosingReply() async throws {
        let first = try envelope(validJSON)
        let bad = try envelope(#"{"memories":[{"key":"walking_time","content":"喜欢白天散步","kind":"preference","evidence":"我喜欢白天散步"}]}"#)
        var chats = 0
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            chats += 1; return (200, chats == 1 ? first : bad)
        }
        let result = try await client().respond(messages: [.init(role: "user", content: "我喜欢晚上散步。")], memories: [], name: "小禾")
        XCTAssertEqual(chats, 2)
        XCTAssertEqual(result.reply, "我在，慢慢说。")
        XCTAssertTrue(result.memories.isEmpty)
        XCTAssertNotNil(result.memoryIssue)
    }
    func testFallbackNeverSendsSecondPromptIfModelBecameRemote() async throws {
        let first = try envelope(validJSON)
        var shows = 0; var chats = 0
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" {
                shows += 1
                return (200, Data((shows == 1 ? #"{"details":{"format":"gguf"}}"# : #"{"details":{"format":"gguf"},"remote_model":"cloud-model"}"#).utf8))
            }
            chats += 1; return (200, first)
        }
        let result = try await client().respond(messages: [.init(role: "user", content: "我喜欢晚上散步。")], memories: [], name: "小禾")
        XCTAssertEqual(shows, 2)
        XCTAssertEqual(chats, 1)
        XCTAssertEqual(result.reply, "我在，慢慢说。")
        XCTAssertTrue(result.memories.isEmpty)
        XCTAssertNotNil(result.memoryIssue)
    }

    func testOptionalExtractionTimeoutPreservesReplyAndCancelsDelayedTransport() async throws {
        let first = try envelope(validJSON)
        let second = try envelope(#"{"memories":[{"key":"walking_time","content":"喜欢晚上散步","kind":"preference","evidence":"我喜欢晚上散步"}]}"#)
        let cancellation = expectation(description: "Delayed extraction transport canceled")
        var chats = 0
        ModelTransport.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data(#"{"details":{"format":"gguf"}}"#.utf8)) }
            chats += 1; return (200, chats == 1 ? first : second)
        }
        ModelTransport.responseDelay = { request in request.url?.path == "/api/chat" && chats == 2 ? 0.4 : 0 }
        ModelTransport.onDelayedCancellation = { cancellation.fulfill() }
        defer { ModelTransport.responseDelay = nil; ModelTransport.onDelayedCancellation = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelTransport.self]
        let client = OllamaClient(session: URLSession(configuration: configuration), memoryExtractionTimeout: 0.03)
        let result = try await client.respond(messages: [.init(role: "user", content: "我喜欢晚上散步。")], memories: [], name: "小禾")
        XCTAssertEqual(result.reply, "我在，慢慢说。")
        XCTAssertTrue(result.memories.isEmpty)
        XCTAssertNotNil(result.memoryIssue)
        await fulfillment(of: [cancellation], timeout: 1)
    }

}
