import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

/// Hands out one shared HistoryManager/ChatStore per profile so multiple windows
/// on the same profile write through a single instance instead of racing on the
/// same JSON files (last-write-wins data loss). Weak references keep the stores
/// alive only while at least one session uses them.
enum ProfileStoreRegistry {
    private struct WeakStores {
        weak var history: HistoryManager?
        weak var chats: ChatStore?
    }
    private static var cache: [UUID: WeakStores] = [:]

    static func stores(for profileId: UUID) -> (history: HistoryManager, chats: ChatStore) {
        var entry = cache[profileId] ?? WeakStores()
        let history = entry.history ?? HistoryManager(profileId: profileId)
        let chats = entry.chats ?? ChatStore(profileId: profileId)
        entry.history = history
        entry.chats = chats
        cache[profileId] = entry
        return (history, chats)
    }
}

/// Browser state owned by exactly one profile.
final class ProfileSession: ObservableObject {
    let profileId: UUID
    let tabManager: TabManager
    let webViewWrapper: WebViewWrapper
    let historyManager: HistoryManager
    let chatStore: ChatStore

    private var cancellables: Set<AnyCancellable> = []

    // Avoid the MainActor isolated-deinit executor hop that double-frees
    // task-local storage on current macOS runtimes (swiftlang/swift#88036).
    nonisolated deinit {}

    init(profileId: UUID, dataStore: WKWebsiteDataStore) {
        self.profileId = profileId
        self.tabManager = TabManager()
        let stores = ProfileStoreRegistry.stores(for: profileId)
        self.historyManager = stores.history
        self.chatStore = stores.chats
        self.webViewWrapper = WebViewWrapper(profileId: profileId, dataStore: dataStore)

        webViewWrapper.tabManager = tabManager
        webViewWrapper.onNavigationFinished = { [weak tabManager, weak historyManager] tabId, url, title in
            tabManager?.navigate(tab: tabId, to: url)
            tabManager?.updateTitle(tab: tabId, title: title)
            historyManager?.recordPageVisit(url: url, title: title)
        }

        tabManager.objectWillChange
            .merge(with: webViewWrapper.objectWillChange, historyManager.objectWillChange, chatStore.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        let tabId = tabManager.newTab(url: nil)
        webViewWrapper.setActiveTab(tabId)
    }

    func activate() {
        guard let tabId = tabManager.currentTab else { return }
        webViewWrapper.setActiveTab(tabId)
        guard let url = tabManager.tabURL[tabId] ?? nil,
              url.absoluteString != "about:blank",
              url.scheme != "luma",
              webViewWrapper.webViewIfLoaded(for: tabId) == nil else { return }
        webViewWrapper.load(url: url, in: tabId)
    }

    func suspend() {
        historyManager.flush()
        chatStore.flush()
        webViewWrapper.removeAllWebViews()
    }
}

/// Owns the per-profile sessions used by a single browser window.
final class BrowserSessionStore: ObservableObject {
    @Published private(set) var activeProfileId: UUID
    @Published private(set) var activeSession: ProfileSession

    private let profileManager: ProfileManager
    private var sessions: [UUID: ProfileSession] = [:]
    private var suspensionTasks: [UUID: DispatchWorkItem] = [:]
    private var activeSessionSubscription: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?

    init(initialProfileId: UUID? = nil, profileManager: ProfileManager = .shared) {
        self.profileManager = profileManager
        let id = profileManager.validProfileId(initialProfileId ?? profileManager.lastActiveProfileId)
        let session = ProfileSession(profileId: id, dataStore: profileManager.dataStore(for: id))
        self.activeProfileId = id
        self.activeSession = session
        self.sessions[id] = session
        subscribeToActiveSession()
        // Persist history/chats even when the app quits without the view disappearing first.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flush()
        }
    }

    // nonisolated to avoid the MainActor isolated-deinit executor hop
    // (swiftlang/swift#88036); NotificationCenter removal is thread-safe.
    nonisolated deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func switchTo(profileId: UUID) {
        let id = profileManager.validProfileId(profileId)
        guard id != activeProfileId else { return }

        let outgoingId = activeProfileId
        scheduleSuspension(for: outgoingId)
        suspensionTasks[id]?.cancel()
        suspensionTasks.removeValue(forKey: id)

        let session = sessions[id] ?? ProfileSession(
            profileId: id,
            dataStore: profileManager.dataStore(for: id)
        )
        sessions[id] = session
        activeProfileId = id
        activeSession = session
        profileManager.markLastActive(profileId: id)
        subscribeToActiveSession()
        session.activate()
    }

    func removeSession(profileId: UUID) {
        suspensionTasks[profileId]?.cancel()
        suspensionTasks.removeValue(forKey: profileId)
        sessions.removeValue(forKey: profileId)?.suspend()
    }

    /// Tears down sessions whose profiles no longer exist (e.g. deleted while inactive).
    func pruneSessions(keeping validProfileIds: Set<UUID>) {
        for id in sessions.keys where !validProfileIds.contains(id) && id != activeProfileId {
            removeSession(profileId: id)
        }
    }

    func flush() {
        sessions.values.forEach {
            $0.historyManager.flush()
            $0.chatStore.flush()
        }
    }

    private func subscribeToActiveSession() {
        activeSessionSubscription = activeSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func scheduleSuspension(for profileId: UUID) {
        suspensionTasks[profileId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeProfileId != profileId else { return }
            // Suspend and release: keeping suspended sessions in the map would
            // retain their TabManager/WebViewWrapper/stores for the window's lifetime.
            self.sessions.removeValue(forKey: profileId)?.suspend()
            self.suspensionTasks.removeValue(forKey: profileId)
        }
        suspensionTasks[profileId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }
}
