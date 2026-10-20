import AppKit
import AVFoundation
import WebKit
import SwiftUI
import CompanionCore

/// Authentication and WebSocket live in native code; WebKit receives only PCM and turn IDs.
@MainActor final class DoubaoRealtime: NSObject, ObservableObject, RealtimeDriving, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var webView: WKWebView?
    var onReady: (() -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    private var epoch = 0
    private var starting: Task<Void, Never>?, receiving: Task<Void, Never>?, writing: Task<Void, Never>?, deadline: Task<Void, Never>?
    private var session: URLSession?, socket: URLSessionWebSocketTask?
    private var request: URLRequest?, configuration: [String: Any]?
    private var queue: [(Data, Bool, Int)] = []
    private var sessionID = "", ready = false, authorized = false
    private var inputGeneration = 0, textGeneration = 0
    private var awaitingTextAck = false
    private var queuedText: (text: String, generation: Int)?
    private var question = "", reply = "", audioReply = "", transcript = ""
    private var suppressed = false, rejected: Set<String> = []
    private var ttsCaption = "", chatCaption: String?
    private var chatFinished = false, playbackDone = false, captionPublished = false
    private let origin = URL(string: "https://presence.invalid/")!

    private let packetSink: ((Data) async throws -> Void)?
    private var dialogID = ""
    private var contextRevision: Int?
    private var contextDispatched = false
    init(packetSink: ((Data) async throws -> Void)? = nil) { self.packetSink = packetSink; super.init() }
    func updateMemoryContext(_ configuration: RealtimeConfiguration, revision: Int) {
        guard ready, contextRevision == nil else { event("memory_context.failed", ["revision": revision]); return }
        do {
            let body = try DoubaoPacket.memoryUpdate(configuration, dialogID: dialogID)
            contextRevision = revision; contextDispatched = false
            enqueue(event: 201, body: body)
        } catch { event("memory_context.failed", ["revision": revision]) }
    }

    func start(key: String, configuration: RealtimeConfiguration) {
        stop(); let token = epoch
        do {
            request = try JSONDecoder().decode(DoubaoCredentials.self, from: Data(key.utf8)).request()
            self.configuration = try DoubaoPacket.session(configuration)
        } catch { fail((error as? LocalizedError)?.errorDescription ?? DoubaoError.credentials.localizedDescription); return }
        sessionID = UUID().uuidString
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 35_000_000_000) } catch { return }
            guard let self, self.epoch == token else { return }
            self.fail("豆包连接超时，麦克风已关闭。请检查网络和服务开通状态。")
        }
        starting = Task { [weak self] in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed = status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .audio) : status == .authorized
            guard !Task.isCancelled, self.epoch == token else { return }
            guard allowed else { self.fail("请在系统设置中允许在场使用麦克风。"); return }
            self.authorized = true; self.makePage()
        }
    }
    private func makePage() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(DoubaoMessageProxy(owner: self), name: "doubao")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        view.navigationDelegate = self; view.uiDelegate = self; webView = view
        guard let url = Bundle.module.url(forResource: "doubao", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) else { fail("豆包语音组件缺失，请重新安装。"); return }
        view.loadHTMLString("""
        <!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' blob:; worker-src blob:; media-src blob:; connect-src 'none'"><body><script>\(script)</script></body>
        """, baseURL: origin)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, request != nil else { return }; let token = epoch
        starting = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                let active = try await webView.callAsyncJavaScript("return await window.doubao.start();", arguments: [:], in: nil, contentWorld: .page) as? Bool
                guard !Task.isCancelled, self.epoch == token, active == true, let request = self.request else { return }
                self.request = nil
                let settings = URLSessionConfiguration.ephemeral; settings.urlCache = nil; settings.httpCookieStorage = nil
                let session = URLSession(configuration: settings, delegate: DoubaoNoRedirect(), delegateQueue: nil)
                self.session = session
                let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 1_048_800; self.socket = socket
                socket.resume(); self.enqueue(event: 1)
                self.receiving = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            guard let self, self.epoch == token else { return }
                            guard case let .data(data) = message else { throw DoubaoError.protocolError }
                            try self.receive(DoubaoPacket.decode(data))
                        }
                    } catch {
                        guard let self, self.epoch == token, !Task.isCancelled else { return }
                        self.fail(DoubaoError.connection.localizedDescription)
                    }
                }
            } catch {
                guard self.epoch == token, !Task.isCancelled else { return }
                self.fail("无法开启豆包收音组件，请检查麦克风权限后重试。")
            }
        }
    }
    private func enqueue(event: Int, body: [String: Any] = [:], audio: Data? = nil) {
        guard socket != nil || packetSink != nil else { return }
        do {
            let data = try DoubaoPacket.encode(event: event, sessionID: event >= 100 ? sessionID : nil,
                                              payload: audio ?? JSONSerialization.data(withJSONObject: body), audio: audio != nil)
            guard queue.count < 100 else { fail("网络发送跟不上收音，已关闭麦克风。请检查网络后重试。"); return }
            queue.append((data, audio != nil, event)); pump()
        } catch { fail(DoubaoError.protocolError.localizedDescription) }
    }
    private func pump() {
        guard writing == nil, socket != nil || packetSink != nil else { return }; let token = epoch
        let socket = socket, packetSink = packetSink
        writing = Task { [weak self] in
            guard let self else { return }
            do {
                while !self.queue.isEmpty {
                    let item = self.queue.removeFirst()
                    if item.2 == 201 { self.contextDispatched = true }
                    if let packetSink { try await packetSink(item.0) }
                    else if let socket { try await socket.send(.data(item.0)) }
                    guard !Task.isCancelled, self.epoch == token else { return }
                    if item.1 { self.invoke("window.doubao.ack();") }
                }
                self.writing = nil
            } catch {
                guard !Task.isCancelled, self.epoch == token else { return }
                self.fail(DoubaoError.connection.localizedDescription)
            }
        }
    }
    private func event(_ type: String, _ fields: [String: Any] = [:]) { var value = fields; value["type"] = type; onEvent?(value) }
    private func beginReply(_ body: [String: Any]) -> Bool {
        guard !suppressed, let id = body["reply_id"] as? String, !id.isEmpty, !rejected.contains(id),
              let q = body["question_id"] as? String, q == question else { return false }
        if reply != id {
            reply = id; resetCaption()
            event("response.created", ["response": ["id": id]])
        }
        return !suppressed
    }
    func receive(_ packet: DoubaoPacket) throws {
        if let id = packet.sessionID, id != sessionID { return }
        let body = (try? JSONSerialization.jsonObject(with: packet.payload)) as? [String: Any] ?? [:]
        switch packet.event {
        case 50: if let configuration { self.configuration = nil; enqueue(event: 100, body: configuration) }
        case 150:
            guard !ready else { return }; ready = true; deadline?.cancel(); deadline = nil
            dialogID = body["dialog_id"] as? String ?? ""
            invoke("window.doubao.activate();"); onReady?()
        case 251:
            if contextDispatched, let revision = contextRevision { contextDispatched = false; contextRevision = nil; event("memory_context.updated", ["revision": revision]) }
        case 51, 52, 152, 153, 599: throw DoubaoError.connection
        case 450:
            inputGeneration += 1; queuedText = nil
            interrupt(); suppressed = false; reply = ""; audioReply = ""; transcript = ""
            question = body["question_id"] as? String ?? UUID().uuidString
            event("input_audio_buffer.speech_started"); event("input_audio_buffer.committed", ["item_id": question])
        case 451:
            if ready, let results = body["results"] as? [[String: Any]], let text = results.last?["text"] as? String, !text.isEmpty {
                event("memory_context.query", ["text": String(text.prefix(4000))])
            }
            if let results = body["results"] as? [[String: Any]], let result = results.last,
               result["is_interim"] as? Bool == false, let text = result["text"] as? String { transcript = String(text.prefix(4000)) }
        case 459:
            if !transcript.isEmpty { event("conversation.item.input_audio_transcription.completed", ["item_id": question, "transcript": transcript]); transcript = "" }
            event("input_audio_buffer.speech_stopped")
        case 553:
            guard awaitingTextAck else { return }
            awaitingTextAck = false
            if let queued = queuedText {
                queuedText = nil
                if queued.generation == inputGeneration { submitText(queued.text, generation: queued.generation) }
            } else if textGeneration == inputGeneration {
                question = body["question_id"] as? String ?? ""
            }
        case 350:
            audioReply = body["reply_id"] as? String ?? ""
            guard beginReply(body) else {
                // A manually stopped response may not have emitted any PCM yet.
                if !audioReply.isEmpty, !rejected.contains(audioReply) {
                    rejected.insert(audioReply)
                    enqueue(event: 513, body: ["item_id": audioReply, "audio_end_ms": 0])
                }
                return
            }
            invoke("window.doubao.begin(id);", ["id": reply])
            if let text = body["text"] as? String { ttsCaption = String((ttsCaption + text).prefix(8000)) }
        case 550:
            guard beginReply(body), let content = body["content"] as? String, !content.isEmpty else { return }
            chatCaption = String(((chatCaption ?? "") + content).prefix(8000))
        case 559:
            guard beginReply(body) else { return }
            chatFinished = true; publishCaptionIfReady()
        case 352:
            guard ready, !suppressed, !reply.isEmpty, audioReply == reply, !rejected.contains(reply) else { return }
            guard !packet.payload.isEmpty, packet.payload.count % 2 == 0 else { throw DoubaoError.protocolError }
            event("output_audio_buffer.started")
            invoke("window.doubao.play(data,id);", ["data": packet.payload.base64EncodedString(), "id": reply])
        case 359:
            guard !suppressed, body["reply_id"] as? String == reply, !reply.isEmpty else { return }
            invoke("window.doubao.end(id);", ["id": reply])
            event("response.done", ["response": ["id": reply, "status": "completed", "output": []]])
        default: break
        }
    }
    func send(_ value: [String: Any]) {
        guard ready, value["type"] as? String == "conversation.item.create",
              let item = value["item"] as? [String: Any], item["role"] as? String == "user",
              let content = item["content"] as? [[String: Any]], let text = content.first?["text"] as? String else { return }
        suppressed = false; reply = ""; audioReply = ""; question = ""
        inputGeneration += 1
        let bounded = String(text.prefix(4000))
        // Only one unacknowledged query is on the wire: 553 has no client correlation ID.
        if awaitingTextAck { queuedText = (bounded, inputGeneration) }
        else { submitText(bounded, generation: inputGeneration) }
    }
    private func submitText(_ text: String, generation: Int) {
        awaitingTextAck = true; textGeneration = generation
        enqueue(event: 501, body: ["content": text])
    }
    func interrupt() {
        inputGeneration += 1; queuedText = nil
        suppressed = true
        if !reply.isEmpty { rejected.insert(reply) }
        resetCaption()
        let token = epoch, interruptedReply = reply
        // Consume the fallback once; repeated stops must not truncate heard audio back to zero.
        reply = ""; audioReply = ""
        webView?.callAsyncJavaScript("return window.doubao.interrupt();", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.epoch == token else { return }
            guard case let .success(value) = result, let value = value as? [String: Any] else { self.fail(DoubaoError.connection.localizedDescription); return }
            let playbackID = value["id"] as? String ?? ""
            let id = playbackID.isEmpty ? interruptedReply : playbackID
            if !id.isEmpty { self.enqueue(event: 513, body: ["item_id": id, "audio_end_ms": playbackID.isEmpty ? 0 : max(0, value["ms"] as? Int ?? 0)]) }
        }
    }
    private func invoke(_ js: String, _ args: [String: Any] = [:]) {
        let token = epoch
        webView?.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { [weak self] result in
            guard let self, self.epoch == token else { return }
            if case .failure = result { self.fail("音频组件中断，麦克风已关闭，请重新开启。"); }
        }
    }
    fileprivate func received(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == origin.host,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "audio":
            guard ready, let encoded = body["data"] as? String, encoded.count <= 1024, let data = Data(base64Encoded: encoded), data.count == 640 else { return }
            enqueue(event: 200, audio: data)
        case "played":
            if let id = body["id"] as? String { playbackFinished(id) }
        case "failure":
            fail(body["code"] as? String == "audio_interrupted"
                 ? "声音被系统暂停，通话已结束。请确认音频设备可用后，重新打电话。"
                 : "音频设备或缓冲区中断，麦克风已关闭。请重新打电话。")
        default: break
        }
    }
    func playbackFinished(_ id: String) {
        guard !suppressed, !id.isEmpty, id == reply, !rejected.contains(id), !playbackDone else { return }
        playbackDone = true; publishCaptionIfReady()
        event("output_audio_buffer.stopped", ["response_id": id])
    }
    private func resetCaption() {
        ttsCaption = ""; chatCaption = nil
        chatFinished = false; playbackDone = false; captionPublished = false
    }
    private func publishCaptionIfReady() {
        guard playbackDone, !captionPublished, !suppressed,
              chatCaption == nil || chatFinished else { return }
        // ChatResponse is the authoritative reply stream; never append it to TTS text.
        let text = (chatCaption ?? ttsCaption).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        captionPublished = true
        event("response.output_audio_transcript.done", ["response_id": reply, "transcript": text])
    }
    func stop() {
        epoch += 1; ready = false; authorized = false
        starting?.cancel(); receiving?.cancel(); writing?.cancel(); deadline?.cancel()
        starting = nil; receiving = nil; writing = nil; deadline = nil
        socket?.cancel(with: .normalClosure, reason: nil); session?.invalidateAndCancel(); socket = nil; session = nil
        dialogID = ""; contextRevision = nil; contextDispatched = false
        request = nil; configuration = nil; queue.removeAll(); resetCaption(); rejected.removeAll()
        question = ""; reply = ""; audioReply = ""; transcript = ""; suppressed = false
        inputGeneration = 0; textGeneration = 0; awaitingTextAck = false; queuedText = nil
        if let view = webView {
            view.setMicrophoneCaptureState(.none); view.pauseAllMediaPlayback()
            view.evaluateJavaScript("window.doubao && window.doubao.stop();", completionHandler: nil)
            view.configuration.userContentController.removeScriptMessageHandler(forName: "doubao")
            view.navigationDelegate = nil; view.uiDelegate = nil
        }
        webView = nil
    }
    private func fail(_ message: String) { stop(); onFailure?(message) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(webView === self.webView && authorized && frame.isMainFrame && origin.protocol == "https" && origin.host == self.origin.host && type == .microphone ? .grant : .deny)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(webView === self.webView && (url?.absoluteString == "about:blank" || url == origin) ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === self.webView { fail(DoubaoError.connection.localizedDescription) } }
}
private final class DoubaoNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor private final class DoubaoMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: DoubaoRealtime?
    init(owner: DoubaoRealtime) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.received(message) }
}
struct DoubaoMediaHost: NSViewRepresentable {
    @ObservedObject var driver: DoubaoRealtime
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ host: NSView, context: Context) {
        if host.subviews.first === driver.webView { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        if let view = driver.webView { view.frame = NSRect(x: 0, y: 0, width: 2, height: 2); host.addSubview(view) }
    }
}
