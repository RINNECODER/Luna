import SwiftUI
import UniformTypeIdentifiers

/// Helium-style horizontal tabs: favorites and pinned tabs as icon-only tabs,
/// Today tabs with titles, thin separators, the active tab on a soft fill.
struct HorizontalTabStrip: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var web: WebViewWrapper
    var height: CGFloat = 30
    let onActivate: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNewTab: () -> Void
    /// Dropped tab, target tab: open them side by side.
    let onSplit: (UUID, UUID) -> Void

    /// Tab being dragged (set when a drag starts in this strip).
    @State private var dragging: UUID?
    /// Tab the drag is resting on the middle of; dropping there splits.
    @State private var splitTarget: UUID?

    private static let iconTabWidth: CGFloat = 38
    private static let minTabWidth: CGFloat = 72
    private static let maxTabWidth: CGFloat = 220

    var body: some View {
        let ws = store.workspace
        let ids = ws.orderedTabIds()
        let persistent = Set(ws.favorites + ws.activeSpace.pinned.flatMap(\.tabIds))
        GeometryReader { geo in
            let iconCount = ids.filter { persistent.contains($0) }.count
            let titled = ids.count - iconCount
            let available = geo.size.width - CGFloat(iconCount) * Self.iconTabWidth - 34
            let width = titled > 0 ? min(Self.maxTabWidth, max(Self.minTabWidth, available / CGFloat(titled))) : 0

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        if let tab = ws.tabs[id] {
                            let iconOnly = persistent.contains(id)
                            let tabWidth = iconOnly ? Self.iconTabWidth : width
                            let split = ws.splitGroup(containing: id)
                            StripTab(
                                tab: tab,
                                faviconURL: web.faviconURLByTab[id] ?? nil,
                                isActive: ws.activeTabId == id,
                                isLoading: web.loadingProgressByTab[id] != nil,
                                iconOnly: iconOnly,
                                showsSeparator: index > 0 && ws.activeTabId != id && ws.activeTabId != ids[index - 1]
                                    && !(split != nil && split?.panes.contains(ids[index - 1]) == true),
                                isSplitTarget: splitTarget == id,
                                inSplit: split != nil,
                                isVisible: ws.visibleTabIds.contains(id),
                                onSelect: { onActivate(id) },
                                onClose: { onClose(id) },
                                onSplitWithCurrent: ws.activeTabId.flatMap { active in
                                    active != id && !ws.isFavorite(active) && !ws.isFavorite(id) ? { onSplit(id, active) } : nil
                                },
                                onRemoveFromSplit: split.map { _ in { store.removeFromSplit(id) } }
                            )
                            .frame(width: tabWidth, height: height)
                            .onDrag {
                                dragging = id
                                return Self.itemProvider(for: id)
                            }
                            .onDrop(of: [.lunaNode], delegate: StripDropDelegate(
                                target: id, width: tabWidth, store: store,
                                dragging: $dragging, splitTarget: $splitTarget, onSplit: onSplit))
                        }
                    }
                    Button(action: onNewTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: height - 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Tab (⌘T)")
                    .padding(.leading, 4)
                }
                .background(NonDraggableWindowView())
                .animation(.spring(response: 0.25, dampingFraction: 0.86), value: ids)
            }
            .scrollDisabled(titled == 0 || CGFloat(titled) * Self.minTabWidth <= available)
        }
        .frame(height: height)
    }

    static func itemProvider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.lunaNode.identifier, visibility: .ownProcess) { done in
            done(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

extension UTType {
    /// In-app drag type for tabs (same identifier as the sidebar's pasteboard type).
    static let lunaNode = UTType(exportedAs: "com.luna.browser.node")
}

private struct StripTab: View {
    let tab: Tab
    let faviconURL: URL?
    let isActive: Bool
    let isLoading: Bool
    let iconOnly: Bool
    let showsSeparator: Bool
    var isSplitTarget = false
    var inSplit = false
    var isVisible = false
    let onSelect: () -> Void
    let onClose: () -> Void
    var onSplitWithCurrent: (() -> Void)?
    var onRemoveFromSplit: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                TabIcon(tab: tab, faviconURL: faviconURL)
                    .opacity(isLoading ? 0.35 : 1)
                if isLoading { ProgressView().controlSize(.mini) }
            }
            .frame(width: 16, height: 16)
            if !iconOnly {
                Text(displayTitle(for: tab))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isActive ? 1 : 0)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, iconOnly ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // Split partners on screen get a lighter fill than the focused pane.
                .fill(.quaternary.opacity(isActive ? 1 : (isVisible ? 0.6 : (isHovered ? 0.5 : 0))))
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
        )
        .overlay {
            // Drop here to open side by side.
            if isSplitTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                    .overlay(Image(systemName: "rectangle.split.2x1").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if showsSeparator {
                Rectangle().fill(.separator).frame(width: 1, height: 14)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(displayTitle(for: tab))
        .contextMenu {
            if let onSplitWithCurrent {
                Button("Open in Split View with Current Tab", action: onSplitWithCurrent)
            }
            if let onRemoveFromSplit {
                Button("Remove from Split View", action: onRemoveFromSplit)
            }
            Button("Close Tab", action: onClose)
        }
    }
}

/// Live reordering: the dragged tab slides in front of or behind the tab
/// under the pointer. Resting on a tab's middle third targets a split instead.
private struct StripDropDelegate: DropDelegate {
    let target: UUID
    let width: CGFloat
    let store: WorkspaceStore
    @Binding var dragging: UUID?
    @Binding var splitTarget: UUID?
    let onSplit: (UUID, UUID) -> Void

    private func canSplit(_ dragged: UUID) -> Bool {
        var trial = store.workspace
        return trial.splitTab(dragged, onto: target) != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let dragged = dragging, dragged != target else { return DropProposal(operation: .move) }
        let x = info.location.x
        if x > width * 0.3, x < width * 0.7, canSplit(dragged) {
            if splitTarget != target { splitTarget = target }
        } else {
            if splitTarget == target { splitTarget = nil }
            let after = x >= width / 2
            let order = store.orderedTabIds
            if let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target),
               after ? from != to + 1 : from != to - 1 {
                store.moveTab(dragged, nextTo: target, after: after)
            }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if splitTarget == target { splitTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragged = dragging, splitTarget == target { onSplit(dragged, target) }
        dragging = nil
        splitTarget = nil
        return true
    }
}
