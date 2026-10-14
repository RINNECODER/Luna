import SwiftUI
import WebKit

/// Toolbar buttons for loaded extensions' actions (icon, badge, popup).
struct ExtensionButtons: View {
    @ObservedObject var host: ExtensionHost
    var maxVisible = 4

    var body: some View {
        let loaded = host.loaded
        // Reading the revision makes the buttons refresh when an action changes.
        let _ = host.actionRevision
        HStack(spacing: 2) {
            ForEach(loaded.prefix(maxVisible), id: \.record.id) { item in
                ExtensionButton(host: host, record: item.record, context: item.context)
            }
            if loaded.count > maxVisible {
                Menu {
                    ForEach(loaded.dropFirst(maxVisible), id: \.record.id) { item in
                        Button(item.record.name) { host.performAction(item.context) }
                    }
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More extensions")
            }
        }
    }
}

private struct ExtensionButton: View {
    let host: ExtensionHost
    let record: ExtensionLibrary.Record
    let context: WKWebExtensionContext
    @State private var hovering = false

    var body: some View {
        let action = context.action(for: host.activeTabAdapter)
        let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16))
        let badge = action?.badgeText ?? ""
        Button { host.performAction(context) } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 13))
                    }
                }
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(hovering ? 1 : 0)))
                .opacity(action?.isEnabled == false ? 0.45 : 1)
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 2, y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action?.label ?? record.name)
        .background(PopupAnchor { host.popupAnchors[record.id] = $0 })
        .contextMenu {
            if context.optionsPageURL != nil {
                Button("Options") { _ = host.openTab(url: context.optionsPageURL, activate: true) }
            }
            Button("Turn Off") { ExtensionLibrary.shared.setEnabled(record, false) }
            Divider()
            ManageExtensionsButton()
        }
    }
}

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

/// Hands the hosting NSView to the extension host so popups can anchor to it.
private struct PopupAnchor: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { register(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
