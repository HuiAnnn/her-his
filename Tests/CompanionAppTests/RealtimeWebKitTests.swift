import XCTest
import WebKit
@testable import CompanionApp

@MainActor final class RealtimeWebKitTests: XCTestCase {
    func testDoubaoWorkletLoadsUnderPackagedCSPWithoutMicrophone() async throws {
        let ready = expectation(description: "Doubao page loaded")
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config), delegate = PageDelegate { ready.fulfill() }
        view.navigationDelegate = delegate
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("Sources/CompanionApp/Resources/doubao.js"), encoding: .utf8)
        view.loadHTMLString("""
        <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' blob:; worker-src blob:; media-src blob:; connect-src 'none'"><script>\(script)</script>
        """, baseURL: URL(string: "https://presence.invalid/")!)
        await fulfillment(of: [ready], timeout: 10)
        let result = try await view.callAsyncJavaScript("""
        const context = new AudioContext();
        const url=URL.createObjectURL(new Blob(["class Probe extends AudioWorkletProcessor { process(){return true;} } registerProcessor('probe',Probe);"],{type:'text/javascript'}));
        try { await context.audioWorklet.addModule(url); return typeof window.doubao.start === 'function'; }
        finally { URL.revokeObjectURL(url); await context.close(); }
        """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }
    func testBundledBridgeRunsInSecureWebKitContextWithoutCapturing() async throws {
        let ready = expectation(description: "local page loaded")
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let delegate = PageDelegate { ready.fulfill() }
        view.navigationDelegate = delegate
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("Sources/CompanionApp/Resources/realtime.js"), encoding: .utf8)
        view.loadHTMLString("<!doctype html><script>\(script)</script>", baseURL: URL(string: "https://presence.invalid/")!)
        await fulfillment(of: [ready], timeout: 10)
        let result = try await view.evaluateJavaScript("({secure: window.isSecureContext, media: !!navigator.mediaDevices, peer: typeof RTCPeerConnection, bridge: typeof window.presence.start, origin: window.origin})") as? [String: Any]
        XCTAssertEqual(result?["secure"] as? Bool, true)
        XCTAssertEqual(result?["media"] as? Bool, true)
        XCTAssertEqual(result?["peer"] as? String, "function")
        XCTAssertEqual(result?["bridge"] as? String, "function")
        XCTAssertEqual(result?["origin"] as? String, "https://presence.invalid")
    }
}
@MainActor private final class PageDelegate: NSObject, WKNavigationDelegate {
    let ready: () -> Void
    init(ready: @escaping () -> Void) { self.ready = ready }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready() }
}
