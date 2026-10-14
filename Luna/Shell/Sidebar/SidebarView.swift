import SwiftUI

/// Arc-style sidebar: window controls and navigation, favorites, the
/// pinned/today outline, and the space bar. The URL field lives in the
/// top bar that slides in on hover or ⌘L.
struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var web: WebViewWrapper
    let isFullScreen: Bool
    let actions: SidebarActions
    let onToggleSidebar: () -> Void
    let onShowDownloads: () -> Void
    let extensions: ExtensionHost
    /// Profile switcher, supplied by the shell (it owns profile state).
    let profileControl: AnyView

    static let topRowHeight: CGFloat = 38

    private var activeTab: Tab? { store.activeTabId.flatMap(store.tab) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            if !store.workspace.favorites.isEmpty {
                FavoritesGrid(store: store, web: web, actions: actions)
            }
            SidebarOutline(snapshot: .make(store: store, web: web), actions: actions)
                // Source-list rows carry their own inset; line them up with the URL field.
                .padding(.horizontal, -8)
            bottomBar
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 2) {
            // Leave room for the traffic lights.
            Spacer().frame(width: isFullScreen ? 0 : 70)
            ToolbarIconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘S)", action: onToggleSidebar)
            Spacer(minLength: 0)
            ToolbarIconButton(systemName: "chevron.left", help: "Back", isEnabled: web.canGoBackForActiveTab) {
                if let id = store.activeTabId { web.goBack(in: id) }
            }
            ToolbarIconButton(systemName: "chevron.right", help: "Forward", isEnabled: web.canGoForwardForActiveTab) {
                if let id = store.activeTabId { web.goForward(in: id) }
            }
            ToolbarIconButton(systemName: "arrow.clockwise", help: "Reload (⌘R)") {
                if let id = store.activeTabId { web.reload(in: id) }
            }
        }
        .frame(height: Self.topRowHeight)
        .background(WindowDragRegionView())
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 4) {
            profileControl
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(store.workspace.spaces) { space in
                    let isActive = space.id == store.workspace.activeSpaceId
                    Button { store.switchSpace(space.id) } label: {
                        Image(systemName: space.icon)
                            .font(.system(size: isActive ? 11 : 7, weight: .semibold))
                            .foregroundStyle(isActive ? .primary : .tertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(space.name)
                    .contextMenu {
                        Button("Rename Space…") {
                            if let name = TextPrompt.name(title: "Rename Space", initial: space.name) {
                                store.updateSpace(space.id) { $0.name = name }
                            }
                        }
                        if store.workspace.spaces.count > 1 {
                            Button("Delete Space", role: .destructive) {
                                store.deleteSpace(space.id).forEach { web.removeWebView(for: $0) }
                            }
                        }
                    }
                }
            }
            ToolbarIconButton(systemName: "plus", help: "New Space") {
                if let name = TextPrompt.name(title: "New Space", initial: "Space \(store.workspace.spaces.count + 1)") {
                    store.createSpace(name: name)
                    actions.newTab()
                }
            }
            ExtensionButtons(host: extensions, maxVisible: 2)
            ToolbarIconButton(systemName: "arrow.down.circle", help: "Downloads", action: onShowDownloads)
        }
        .frame(height: 28)
    }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var web: WebViewWrapper
    let actions: SidebarActions

    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(store.workspace.favorites, id: \.self) { id in
                if let tab = store.tab(id) {
                    let isActive = store.activeTabId == id
                    Button { actions.activate(id) } label: {
                        TabIcon(tab: tab, faviconURL: web.faviconURLByTab[id] ?? nil, size: 18)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isActive ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.quaternary.opacity(0.6)))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(displayTitle(for: tab))
                    .contextMenu {
                        Button("Remove from Favorites") { store.unpin(id) }
                        Button("Reset Tab") { actions.close(id) }
                    }
                }
            }
        }
    }
}

// MARK: - Toolbar button

/// Borderless toolbar-style icon button with the system hover background.
struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? .secondary : .quaternary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary.opacity(isHovering && isEnabled ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Resize handle

/// Invisible strip on the sidebar's trailing edge; drag to resize.
struct SidebarResizeHandle: View {
    @Binding var width: Double
    static let range: ClosedRange<Double> = 180...420

    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(max(start + value.translation.width, Self.range.lowerBound), Self.range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .offset(x: 3)
    }
}
