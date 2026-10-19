import AppKit
import AVFoundation
import WebKit
import SwiftUI
import CompanionCore

/// Native owns the credential/HTTPS handshake; the isolated page owns media only.
@MainActor final class RealtimeWebRTC: NSObject, ObservableObject, RealtimeDriving, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var webView: WKWebView?
    var onReady: (() -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    private var epoch = 0
    private var starting: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var handshake: (key: String, config: RealtimeConfiguration)?
    private let client: RealtimeClient
    private var mediaAuthorized = false
    private let origin = URL(string: "https://presence.invalid/")!

    init(client: RealtimeClient = .init()) { self.client = client; super.init() }
    func start(key: String, configuration: RealtimeConfiguration) {
        stop()
        let token = epoch
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 35_000_000_000) } catch { return }
            guard let self, self.epoch == token else { return }
            self.fail("实时语音连接超时，麦克风已关闭。请检查网络后重试。")
        }
        starting = Task { [weak self] in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed: Bool
            if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
            else { allowed = status == .authorized }
            guard !Task.isCancelled, self.epoch == token else { return }
            guard allowed else { self.fail("请在系统设置的隐私与安全性中允许在场使用麦克风。"); return }
            self.mediaAuthorized = true
            self.handshake = (key, configuration)
            self.makePage()
        }
    }
    private func makePage() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(RealtimeMessageProxy(owner: self), name: "realtime")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        view.navigationDelegate = self; view.uiDelegate = self
        webView = view
        // Bundle.module resolves the resource in SwiftPM and the packaged app.
        guard let url = Bundle.module.url(forResource: "realtime", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else { fail("实时语音组件缺失，请重新安装应用。"); return }
        view.loadHTMLString("""
        <!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; media-src blob:; connect-src 'none'; style-src 'unsafe-inline'"><body style="margin:0;background:#131415"><script>\(script)</script></body>
        """, baseURL: origin)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let handshake else { return }
        self.handshake = nil
        let token = epoch
        starting = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                guard let offer = try await webView.callAsyncJavaScript("return await window.presence.start();", arguments: [:], in: nil, contentWorld: .page) as? String else { throw RealtimeError.invalidResponse }
                guard !Task.isCancelled, self.epoch == token else { return }
                let answer = try await self.client.createCall(offer: offer, key: handshake.key, configuration: handshake.config)
                guard !Task.isCancelled, self.epoch == token else { return }
                _ = try await webView.callAsyncJavaScript("return await window.presence.answer(sdp);", arguments: ["sdp": answer], in: nil, contentWorld: .page)
            } catch {
                guard !Task.isCancelled, self.epoch == token else { return }
                self.fail((error as? RealtimeError)?.localizedDescription ?? "未能开启实时语音。请检查麦克风权限与网络后重试。")
            }
        }
    }
    func send(_ event: [String: Any]) { invoke("window.presence.send(event);", arguments: ["event": event]) }
    func interrupt() { invoke("window.presence.interrupt();") }
    private func invoke(_ script: String, arguments: [String: Any] = [:]) {
        guard let webView else { return }
        let token = epoch
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self, self.epoch == token else { return }
            if case .failure = result { self.fail(RealtimeError.connection.localizedDescription) }
        }
    }
    func stop() {
        epoch += 1; mediaAuthorized = false
        starting?.cancel(); starting = nil; deadline?.cancel(); deadline = nil; handshake = nil
        if let view = webView {
            view.setMicrophoneCaptureState(.none)
            view.pauseAllMediaPlayback()
            view.evaluateJavaScript("window.presence && window.presence.stop();", completionHandler: nil)
            view.configuration.userContentController.removeScriptMessageHandler(forName: "realtime")
            view.navigationDelegate = nil; view.uiDelegate = nil
        }
        webView = nil
    }
    fileprivate func received(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == origin.host,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready": deadline?.cancel(); deadline = nil; onReady?()
        case "event": if let event = body["event"] as? [String: Any] { onEvent?(event) }
        case "failure": fail(RealtimeError.connection.localizedDescription)
        default: break
        }
    }
    private func fail(_ message: String) { stop(); onFailure?(message) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let valid = webView === self.webView && mediaAuthorized && frame.isMainFrame && origin.protocol == "https" && origin.host == self.origin.host && type == .microphone
        decisionHandler(valid ? .grant : .deny)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(webView === self.webView && (url?.absoluteString == "about:blank" || url == origin) ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }; fail(RealtimeError.connection.localizedDescription)
    }
}
@MainActor private final class RealtimeMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: RealtimeWebRTC?
    init(owner: RealtimeWebRTC) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.received(message) }
}
struct RealtimeMediaHost: NSViewRepresentable {
    @ObservedObject var driver: RealtimeWebRTC
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ host: NSView, context: Context) {
        if host.subviews.first === driver.webView { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        if let webView = driver.webView { webView.frame = NSRect(x: 0, y: 0, width: 2, height: 2); host.addSubview(webView) }
    }
}
