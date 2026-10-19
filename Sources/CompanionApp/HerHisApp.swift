import SwiftUI
import AppKit

@main
struct HerHisApp: App {
    @NSApplicationDelegateAdaptor(PresenceAppDelegate.self) private var delegate
    private var model: CompanionController { delegate.model }
    var body: some Scene {
        WindowGroup {
            CompanionRootView(model: model)
        }
        .defaultSize(width: 1020, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("陪伴") {
                Button("结束这次对话") { model.endConversation() }.keyboardShortcut("e", modifiers: [.command])
                Button("关闭麦克风") { model.disableVoice() }.keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}

/// Cleanup belongs to the application lifetime, including after its windows close.
@MainActor final class PresenceAppDelegate: NSObject, NSApplicationDelegate {
    let model = CompanionController()
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}
