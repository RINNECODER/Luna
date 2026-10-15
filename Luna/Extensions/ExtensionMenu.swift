// Extensions in the ⋯ menu, and the Manage Extensions shortcut.
import SwiftUI
import WebKit

/// Opens Settings on the Extensions pane.
struct ManageExtensionsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Manage Extensions…") {
            SettingsRouter.shared.requestedPane = .extensions
            openSettings()
        }
    }
}

/// Extensions as menu items: each runs its action (popups open from the ⋯
/// button), then "Manage Extensions…".
struct ExtensionsMenuItems: View {
    @ObservedObject var host: ExtensionHost

    var body: some View {
        let _ = host.actionRevision
        let loaded = host.loaded
        if loaded.isEmpty {
            ManageExtensionsButton()
        } else {
            Menu("Extensions") {
                ForEach(loaded, id: \.record.id) { item in
                    Button { host.performAction(item.context) } label: {
                        let action = item.context.action(for: host.activeTabAdapter)
                        if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? item.context.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                            Label { Text(item.record.name) } icon: { Image(nsImage: icon) }
                        } else {
                            Text(item.record.name)
                        }
                    }
                }
                Divider()
                ManageExtensionsButton()
            }
        }
    }
}

/// Hands the hosting NSView to the extension host so popups can anchor to it.
struct PopupAnchor: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { register(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
