#if DEBUG
import AppKit
import SwiftUI

/// Debug-only visual check: when LUNA_SNAPSHOT_PATH is set, writes a PNG of
/// each window's content after LUNA_SNAPSHOT_DELAY seconds (default 4), then
/// keeps running. Web page pixels are out-of-process and may render blank.
/// LUNA_SNAPSHOT_SETTINGS=<pane> also shows a Settings window on that pane.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["LUNA_SNAPSHOT_PATH"] else { return }
        let delay = Double(env["LUNA_SNAPSHOT_DELAY"] ?? "") ?? 4
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
