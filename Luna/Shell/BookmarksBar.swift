import SwiftUI

/// A row of the profile's bookmarks above the page (Settings → Appearance → Bookmarks bar).
struct BookmarksBar: View {
    @ObservedObject var store: BookmarkStore
    /// URL, and whether to open it in a new tab (⌘-click or the context menu).
    let onOpen: (URL, Bool) -> Void
    var onAddCurrentPage: (() -> Void)?

    static let height: CGFloat = 28

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if store.bookmarks.isEmpty {
                    Button {
                        onAddCurrentPage?()
                    } label: {
                        Label("Bookmark This Page", systemImage: "bookmark")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(onAddCurrentPage == nil)
                    .help("Add the current page to the bookmarks bar")
                }
                ForEach(store.bookmarks) { bookmark in
                    BookmarkChip(bookmark: bookmark, onOpen: onOpen, onRemove: { store.remove(bookmark.id) })
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: Self.height)
        .background(NonDraggableWindowView())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmarks bar")
    }
}

private struct BookmarkChip: View {
    let bookmark: Bookmark
    let onOpen: (URL, Bool) -> Void
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            onOpen(bookmark.url, NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(spacing: 5) {
                FaviconView(url: bookmark.url)
                    .frame(width: 14, height: 14)
                Text(bookmark.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .frame(maxWidth: 160)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary.opacity(isHovering ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(bookmark.url.absoluteString)
        .contextMenu {
            Button("Open in New Tab") { onOpen(bookmark.url, true) }
            Divider()
            Button("Remove Bookmark", role: .destructive, action: onRemove)
        }
        .accessibilityLabel(bookmark.title)
    }
}
