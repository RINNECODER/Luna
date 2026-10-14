#if DEBUG
import AppKit
import SwiftUI
import WebKit

/// Debug-only visual check: when LUNA_SNAPSHOT_PATH is set, writes a PNG of
/// each window's content after LUNA_SNAPSHOT_DELAY seconds (default 4), then
/// keeps running. Web page pixels are out-of-process and may render blank.
/// LUNA_SNAPSHOT_SETTINGS=<pane> also shows a Settings window on that pane.
enum DebugSnapshot {
    /// Hosts the AI panel alone over a sample page so its styling can be checked.
    static func showPanelPreview(empty: Bool) {
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let tabs = TabManager()
        web.tabManager = tabs
        let tab = tabs.newTab(url: URL(string: "https://example.com")!)
        web.setActiveTab(tab)
        web.load(url: URL(string: "https://example.com")!, in: tab)
        let sample: [ChatMessage] = empty ? [] : [
            ChatMessage(role: .user, text: "What is this page for?"),
            ChatMessage(role: .assistant, text: "**example.com** is a reserved domain for documentation.\n\n- Safe to use in examples\n- Not a real service\n\nYou can link to it without asking permission."),
        ]
        struct Host: View {
            @State var messages: [ChatMessage]
            @State var open = true
            let web: WebViewWrapper
            let tab: UUID
            var body: some View {
                CommandSurfaceView(isPresented: $open, messages: $messages, webViewWrapper: web,
                                   commandRouter: CommandRouter(), gemini: GeminiClient(apiKeyProvider: { nil }),
                                   ollama: OllamaClient(), historyManager: HistoryManager(profileId: UUID()),
                                   onActionProposed: { _ in }, tabId: tab)
                    .padding(10)
                    .frame(width: 400, height: 640)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: Host(messages: sample, web: web, tab: tab)))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["LUNA_SNAPSHOT_PATH"] else { return }
        let delay = Double(env["LUNA_SNAPSHOT_DELAY"] ?? "") ?? 4
        if let mode = env["LUNA_SNAPSHOT_PANEL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay - 2.5)) { showPanelPreview(empty: mode == "empty") }
        }
        if env["LUNA_SNAPSHOT_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay - 1.5)) {
                let pane = env["LUNA_SNAPSHOT_SETTINGS"].flatMap(SettingsPane.init(rawValue:)) ?? .appearance
                let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(initialPane: pane)))
                window.setContentSize(NSSize(width: 820, height: 600))
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: base).deletingPathExtension()
                    .appendingPathExtension(i == 0 ? "png" : "\(i).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
#endif
