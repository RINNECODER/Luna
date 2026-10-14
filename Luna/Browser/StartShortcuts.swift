// Luna — start page site tiles: the user's own shortcuts followed by the
// sites they visit most (from this profile's history).
import SwiftUI
import Combine

struct SiteShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
}

/// Start page tile settings (Settings → Appearance → Start page).
enum StartPagePrefs {
    static let showShortcuts = "luna_start_shortcuts_enabled"
    static let showFrequent = "luna_start_frequent_enabled"
}

/// User-pinned shortcuts and hidden frequent sites, shared across start pages.
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private static let key = "luna_start_shortcuts"
    private static let hiddenKey = "luna_start_hidden_hosts"

    @Published private(set) var shortcuts: [SiteShortcut]
    /// Frequently visited hosts the user dismissed from the start page.
    @Published private(set) var hiddenHosts: Set<String>

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([SiteShortcut].self, from: data) {
            shortcuts = saved
        } else {
            shortcuts = []
        }
        hiddenHosts = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    func add(_ s: SiteShortcut) { shortcuts.append(s); save() }
    func remove(_ id: UUID) { shortcuts.removeAll { $0.id == id }; save() }
    func removeAll() { shortcuts = []; save() }

    func hide(host: String) {
        hiddenHosts.insert(SiteShortcut.normalizedHost(host))
        UserDefaults.standard.set(Array(hiddenHosts), forKey: Self.hiddenKey)
    }

    func unhideAll() {
        hiddenHosts = []
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
    }
    func update(_ s: SiteShortcut) {
        guard let i = shortcuts.firstIndex(where: { $0.id == s.id }) else { return }
        shortcuts[i] = s
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension HistoryManager {
    /// Most-visited sites over the last 60 days, one per host, recent visits
    /// weighted higher.
    func frequentSites(limit: Int, excludingHosts: Set<String>) -> [SiteShortcut] {
        let cutoff = Date().addingTimeInterval(-60 * 86_400)
        var scores: [String: (score: Double, url: URL)] = [:]
        for event in historyEvents where event.type == .pageVisit && event.timestamp > cutoff {
            guard let raw = event.url, let url = URL(string: raw), let host = url.host?.lowercased(),
                  !excludingHosts.contains(SiteShortcut.normalizedHost(host)) else { continue }
            let key = SiteShortcut.normalizedHost(host)
            let ageDays = Date().timeIntervalSince(event.timestamp) / 86_400
            let weight = 1 / (1 + ageDays / 14)
            let home = URL(string: "\(url.scheme ?? "https")://\(host)") ?? url
            scores[key, default: (0, home)].score += weight
        }
        return scores
            .filter { $0.value.score >= 1.5 }
            .sorted { $0.value.score > $1.value.score }
            .prefix(limit)
            .map { SiteShortcut(title: SiteShortcut.displayName(forHost: $0.key), url: $0.value.url) }
    }
}

extension SiteShortcut {
    static func normalizedHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "mail.google.com" → "Mail", "github.com" → "GitHub"-ish ("Github").
    static func displayName(forHost host: String) -> String {
        let parts = normalizedHost(host).split(separator: ".")
        let label = parts.count > 2 ? parts[parts.count - 3] : (parts.first ?? Substring(host))
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

// MARK: - View

struct StartShortcutsRow: View {
    let history: HistoryManager?
    let onOpen: (URL) -> Void

    @ObservedObject private var store = ShortcutStore.shared
    @AppStorage(StartPagePrefs.showFrequent) private var showFrequent = true
    @State private var frequent: [SiteShortcut] = []
    @State private var addingShortcut = false
    @State private var editing: SiteShortcut?

    private static let tileWidth: CGFloat = 76

    var body: some View {
        GeometryReader { geo in
            // Fit as many tiles as the width allows; pinned ones first.
            let fit = max(1, Int(geo.size.width / Self.tileWidth))
            let pinned = Array(store.shortcuts.prefix(fit - 1))
            let extra = Array(frequent.prefix(max(0, fit - 1 - pinned.count)))
            HStack(spacing: 0) {
                ForEach(pinned) { s in
                    tile(s, isPinned: true)
                }
                ForEach(extra) { s in
                    tile(s, isPinned: false)
                }
                addTile
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 78)
        .onAppear(perform: refreshFrequent)
        .onChange(of: store.shortcuts) { _, _ in refreshFrequent() }
        .onChange(of: store.hiddenHosts) { _, _ in refreshFrequent() }
        .onChange(of: showFrequent) { _, _ in refreshFrequent() }
    }

    private func refreshFrequent() {
        guard showFrequent else { frequent = []; return }
        let pinnedHosts = Set(store.shortcuts.compactMap { $0.url.host.map(SiteShortcut.normalizedHost) })
        frequent = history?.frequentSites(limit: 8, excludingHosts: pinnedHosts.union(store.hiddenHosts)) ?? []
    }

    private func dismiss(_ s: SiteShortcut, isPinned: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            if isPinned { store.remove(s.id) } else if let host = s.url.host { store.hide(host: host) }
        }
    }

    private func tile(_ s: SiteShortcut, isPinned: Bool) -> some View {
        ShortcutTile(title: s.title, help: s.url.host ?? s.url.absoluteString, action: { onOpen(s.url) },
                     onRemove: { dismiss(s, isPinned: isPinned) },
                     removeHelp: isPinned ? "Remove shortcut" : "Don't show this site") {
            FaviconView(url: s.url)
                .scaleEffect(1.15)
        }
        .contextMenu {
            if isPinned {
                Button("Edit…") { editing = s }
                Button("Remove", role: .destructive) { dismiss(s, isPinned: true) }
            } else {
                Button("Add to Shortcuts") { store.add(SiteShortcut(title: s.title, url: s.url)) }
                Button("Don't Show This Site") { dismiss(s, isPinned: false) }
            }
        }
    }

    private var addTile: some View {
        ShortcutTile(title: "Add shortcut", help: "Add a shortcut", action: { addingShortcut = true }) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .popover(isPresented: $addingShortcut, arrowEdge: .bottom) {
            ShortcutEditor(title: "Add Shortcut", confirm: "Add", initial: nil) { store.add($0) }
        }
        .popover(item: $editing, arrowEdge: .bottom) { s in
            ShortcutEditor(title: "Edit Shortcut", confirm: "Save", initial: s) { store.update($0) }
        }
    }
}

/// Small Name + URL form for adding or editing a shortcut.
private struct ShortcutEditor: View {
    let title: String
    let confirm: String
    let initial: SiteShortcut?
    let onSave: (SiteShortcut) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""
    @FocusState private var focus: Field?

    private enum Field { case name, url }

    /// Accepts "github.com" or a full URL; nil until it looks like a site.
    private var url: URL? {
        let raw = urlText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains(" ") else { return nil }
        guard let u = URL(string: raw.contains("://") ? raw : "https://\(raw)"),
              let host = u.host, host.contains(".") else { return nil }
        return u
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name)
                    .focused($focus, equals: .name)
                TextField("URL", text: $urlText, prompt: Text("example.com"))
                    .focused($focus, equals: .url)
                    .onSubmit(save)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            name = initial?.title ?? ""
            urlText = initial?.url.absoluteString ?? ""
            focus = .name
        }
    }

    private func save() {
        guard let url, let host = url.host else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let title = trimmed.isEmpty ? SiteShortcut.displayName(forHost: host) : trimmed
        var s = initial ?? SiteShortcut(title: title, url: url)
        s.title = title
        s.url = url
        onSave(s)
        dismiss()
    }
}

private struct ShortcutTile<Icon: View>: View {
    let title: String
    let help: String
    let action: () -> Void
    var onRemove: (() -> Void)? = nil
    var removeHelp: String = "Remove"
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                icon()
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(hovering ? 0.12 : 0.07))
                    )
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let onRemove, hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(white: 0.28)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(removeHelp)
                .offset(x: -6, y: -5)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
