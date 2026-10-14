import SwiftUI

/// Callbacks the top chrome needs from the shell.
struct TopChromeActions {
    var activate: (UUID) -> Void
    var close: (UUID) -> Void
    var newTab: () -> Void
    var reorder: (Int, Int) -> Void
    var submitAddress: () -> Void
    var goHome: () -> Void
    var toggleAI: () -> Void
    var showDownloads: () -> Void
    var showHistory: () -> Void
}

/// Window chrome for the Compact, Dynamic and Classic layouts.
struct TopChromeView: View {
    let layout: BrowserLayout
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var web: WebViewWrapper
    @Binding var addressText: String
    var addressFocused: FocusState<Bool>.Binding
    let isFullScreen: Bool
    /// False in frameless mode: tabs live in the edge-revealed list instead.
    let showsTabs: Bool
    let downloadsCount: Int
    let profileControl: AnyView
    let actions: TopChromeActions

    @AppStorage(ChromePrefs.centeredAddressBar) private var centeredAddressBar = false
    @AppStorage(ChromePrefs.showHomeButton) private var showHomeButton = false

    static let rowHeight: CGFloat = 40
    static let tabRowHeight: CGFloat = 36

    private var trafficLightInset: CGFloat { isFullScreen ? 8 : 78 }
    private var activeURL: URL? { store.activeTabId.flatMap { store.tab($0)?.url } }

    /// Height of the chrome for a layout, used to place the content below it.
    static func height(for layout: BrowserLayout, showsTabs: Bool) -> CGFloat {
        switch layout {
        case .sidebar: return 0
        case .compact: return rowHeight
        case .dynamic, .classic: return showsTabs ? rowHeight + tabRowHeight : rowHeight
        }
    }

    var body: some View {
        Group {
            switch layout {
            case .classic where showsTabs:
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Spacer().frame(width: trafficLightInset)
                        tabStrip
                    }
                    .frame(height: Self.tabRowHeight)
                    .padding(.trailing, 8)
                    navigationRow(leadingInset: 8)
                }
            case .dynamic where showsTabs:
                VStack(spacing: 0) {
                    navigationRow(leadingInset: trafficLightInset)
                    tabStrip
                        .frame(height: Self.tabRowHeight)
                        .padding(.horizontal, 8)
                }
            case .compact where showsTabs:
                HStack(spacing: 6) {
                    Spacer().frame(width: trafficLightInset)
                    navButtons
                    address
                        .frame(minWidth: 180, idealWidth: 320, maxWidth: 360)
                    tabStrip
                        .frame(maxWidth: .infinity)
                    toolbarIcons
                }
                .padding(.horizontal, 8)
                .frame(height: Self.rowHeight)
            default:
                navigationRow(leadingInset: trafficLightInset)
            }
        }
        .background(WindowDragRegionView())
    }

    // MARK: Pieces

    private func navigationRow(leadingInset: CGFloat) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: max(0, leadingInset - 8))
            navButtons
            if centeredAddressBar {
                Spacer(minLength: 8)
                address.frame(maxWidth: 640)
                Spacer(minLength: 8)
            } else {
                address.frame(maxWidth: .infinity)
            }
            toolbarIcons
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
    }

    private var navButtons: some View {
        HStack(spacing: 0) {
            ToolbarIconButton(systemName: "chevron.left", help: "Back (⌘[)", isEnabled: web.canGoBackForActiveTab) {
                if let id = store.activeTabId { web.goBack(in: id) }
            }
            ToolbarIconButton(systemName: "chevron.right", help: "Forward (⌘])", isEnabled: web.canGoForwardForActiveTab) {
                if let id = store.activeTabId { web.goForward(in: id) }
            }
            ToolbarIconButton(systemName: "arrow.clockwise", help: "Reload (⌘R)") {
                if let id = store.activeTabId { web.reload(in: id) }
            }
            if showHomeButton {
                ToolbarIconButton(systemName: "house", help: "Home", action: actions.goHome)
            }
        }
        .background(NonDraggableWindowView())
    }

    private var address: some View {
        AddressField(
            url: activeURL,
            text: $addressText,
            focused: addressFocused,
            loadingProgress: store.activeTabId.flatMap { web.loadingProgressByTab[$0] },
            centered: centeredAddressBar,
            onSubmit: actions.submitAddress
        )
    }

    private var tabStrip: some View {
        HorizontalTabStrip(
            store: store,
            web: web,
            onActivate: actions.activate,
            onClose: actions.close,
            onNewTab: actions.newTab,
            onReorder: actions.reorder
        )
    }

    private var toolbarIcons: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(systemName: "sparkles", help: "Luna AI (⌘E)", action: actions.toggleAI)
            ZStack(alignment: .topTrailing) {
                ToolbarIconButton(systemName: "arrow.down.circle", help: "Downloads", action: actions.showDownloads)
                if downloadsCount > 0 {
                    Text(downloadsCount > 99 ? "99+" : "\(downloadsCount)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.red))
                        .offset(x: 3, y: -1)
                        .allowsHitTesting(false)
                }
            }
            profileControl
            MoreMenu(actions: actions)
        }
        .background(NonDraggableWindowView())
    }
}

/// The "⋯" menu: tab, history, downloads and settings commands.
struct MoreMenu: View {
    let actions: TopChromeActions

    var body: some View {
        Menu {
            Button("New Tab", action: actions.newTab)
            Divider()
            Button("History", action: actions.showHistory)
            Button("Downloads", action: actions.showDownloads)
            Divider()
            SettingsLink { Text("Settings…") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}
