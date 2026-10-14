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
    let onReorder: (Int, Int) -> Void

    @State private var dragging: UUID?

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
                            StripTab(
                                tab: tab,
                                faviconURL: web.faviconURLByTab[id] ?? nil,
                                isActive: ws.activeTabId == id,
                                isLoading: web.loadingProgressByTab[id] != nil,
                                iconOnly: iconOnly,
                                showsSeparator: index > 0 && ws.activeTabId != id && ws.activeTabId != ids[index - 1],
                                onSelect: { onActivate(id) },
                                onClose: { onClose(id) }
                            )
                            .frame(width: iconOnly ? Self.iconTabWidth : width, height: height)
                            .opacity(dragging == id ? 0.5 : 1)
                            .onDrag {
                                dragging = id
                                return NSItemProvider(object: id.uuidString as NSString)
                            }
                            .onDrop(of: [.plainText], delegate: StripDropDelegate(target: id, ids: ids, dragging: $dragging, onReorder: onReorder))
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
            }
            .scrollDisabled(titled == 0 || CGFloat(titled) * Self.minTabWidth <= available)
        }
        .frame(height: height)
    }
}

private struct StripTab: View {
    let tab: Tab
    let faviconURL: URL?
    let isActive: Bool
    let isLoading: Bool
    let iconOnly: Bool
    let showsSeparator: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

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
                .fill(.quaternary.opacity(isActive ? 1 : (isHovered ? 0.5 : 0)))
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
        )
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
            Button("Close Tab", action: onClose)
        }
    }
}

private struct StripDropDelegate: DropDelegate {
    let target: UUID
    let ids: [UUID]
    @Binding var dragging: UUID?
    let onReorder: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = ids.firstIndex(of: dragging), let to = ids.firstIndex(of: target) else { return }
        onReorder(from, to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
