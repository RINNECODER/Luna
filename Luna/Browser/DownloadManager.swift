// Luma MVP - Download manager and hub
import Foundation
import SwiftUI
import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers

/// A single recent download for the hub.
struct DownloadItem: Identifiable {
    enum State: Equatable {
        case downloading
        case finished
        case failed(String)
        case cancelled
    }

    let id: UUID
    let url: URL
    var fileURL: URL
    let suggestedFilename: String
    let date: Date
    var state: State = .finished
    /// 0…1 while downloading; nil when the server didn't send a size.
    var fraction: Double?
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0
    /// Set after Luna Max renamed the file; used for one-click undo.
    var originalFileURL: URL?
    var isTidying = false

    var displayName: String { fileURL.lastPathComponent }
    var isActive: Bool { state == .downloading }

    init(id: UUID = UUID(), url: URL, fileURL: URL, suggestedFilename: String, date: Date = Date(), state: State = .finished) {
        self.id = id
        self.url = url
        self.fileURL = fileURL
        self.suggestedFilename = suggestedFilename
        self.date = date
        self.state = state
    }
}

/// Manages recent downloads; files are saved to ~/Downloads.
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var recentDownloads: [DownloadItem] = []
    /// Bumped when a download starts or the hub is requested; the Downloads
    /// button in the key window opens its popover in response.
    @Published private(set) var presentRequest = 0
    private let maxRecent = 50
    private let fileManager = FileManager.default
    private var active: [UUID: (download: WKDownload, observation: NSKeyValueObservation)] = [:]

    var downloadsDirectory: URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    private init() {}

    /// Active downloads' combined progress (0…1), or nil when sizes are unknown.
    var activeFraction: Double? {
        let items = recentDownloads.filter(\.isActive)
        let expected = items.reduce(Int64(0)) { $0 + $1.bytesExpected }
        guard !items.isEmpty, expected > 0, items.allSatisfy({ $0.bytesExpected > 0 }) else { return nil }
        return Double(items.reduce(Int64(0)) { $0 + $1.bytesReceived }) / Double(expected)
    }

    var hasActiveDownloads: Bool { recentDownloads.contains(where: \.isActive) }

    func presentHub() { presentRequest += 1 }

    /// Starts tracking a WKDownload that is about to write to `fileURL`.
    @discardableResult
    func begin(_ download: WKDownload, url: URL, fileURL: URL, suggestedFilename: String) -> UUID {
        let item = DownloadItem(url: url, fileURL: fileURL, suggestedFilename: suggestedFilename, state: .downloading)
        let id = item.id
        let observation = download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let expected = progress.totalUnitCount
            DispatchQueue.main.async {
                guard let self, let i = self.recentDownloads.firstIndex(where: { $0.id == id }),
                      self.recentDownloads[i].isActive else { return }
                self.recentDownloads[i].bytesReceived = received
                self.recentDownloads[i].bytesExpected = max(0, expected)
                self.recentDownloads[i].fraction = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
            }
        }
        active[id] = (download, observation)
        insert(item)
        presentHub()
        return id
    }

    func finish(_ id: UUID) {
        active.removeValue(forKey: id)
        guard let i = recentDownloads.firstIndex(where: { $0.id == id }) else { return }
        recentDownloads[i].state = .finished
        recentDownloads[i].fraction = 1
        if LunaMaxPrefs.isOn(LunaMaxPrefs.tidyDownloads) { tidy(id) }
    }

    func fail(_ id: UUID, error: Error) {
        active.removeValue(forKey: id)
        guard let i = recentDownloads.firstIndex(where: { $0.id == id }), recentDownloads[i].isActive else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        recentDownloads[i].state = cancelled ? .cancelled : .failed(error.localizedDescription)
    }

    func cancel(_ id: UUID) {
        guard let entry = active.removeValue(forKey: id) else { return }
        entry.download.cancel { _ in }
        if let i = recentDownloads.firstIndex(where: { $0.id == id }) { recentDownloads[i].state = .cancelled }
    }

    /// Saves bytes the page already has (a `data:` image) straight to Downloads.
    func save(_ data: Data, mimeType: String?, sourceURL: URL) {
        let ext = mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "bin"
        let base = mimeType?.hasPrefix("image/") == true ? "image" : "download"
        var dest = downloadsDirectory.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while fileManager.fileExists(atPath: dest.path) {
            dest = downloadsDirectory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        do {
            try data.write(to: dest)
        } catch {
            return
        }
        insert(DownloadItem(url: sourceURL, fileURL: dest, suggestedFilename: dest.lastPathComponent))
        presentHub()
    }

    /// Call when a file was saved to path outside WKDownload (e.g. URLSession).
    func addDownload(url: URL, fileURL: URL, suggestedFilename: String) {
        let item = DownloadItem(url: url, fileURL: fileURL, suggestedFilename: suggestedFilename)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.insert(item)
            if LunaMaxPrefs.isOn(LunaMaxPrefs.tidyDownloads) { self.tidy(item.id) }
        }
    }

    private func insert(_ item: DownloadItem) {
        recentDownloads.insert(item, at: 0)
        if recentDownloads.count > maxRecent, let last = recentDownloads.lastIndex(where: { !$0.isActive }) {
            recentDownloads.remove(at: last)
        }
    }

    /// Clears finished, failed and cancelled downloads from the list.
    func clearInactive() {
        recentDownloads.removeAll { !$0.isActive }
    }

    // MARK: - Luna Max: tidy downloads

    /// Asks the model for a clearer name and renames the file in place.
    func tidy(_ id: UUID) {
        guard let index = recentDownloads.firstIndex(where: { $0.id == id }), !recentDownloads[index].isTidying else { return }
        let item = recentDownloads[index]
        recentDownloads[index].isTidying = true
        Task {
            let newName = try? await LunaMax.tidyFilename(for: item.fileURL.lastPathComponent, sourceURL: item.url)
            guard let i = recentDownloads.firstIndex(where: { $0.id == id }) else { return }
            recentDownloads[i].isTidying = false
            guard let newName, newName != item.fileURL.lastPathComponent else { return }
            if let renamed = moveFile(recentDownloads[i].fileURL, toName: newName) {
                recentDownloads[i].originalFileURL = recentDownloads[i].originalFileURL ?? recentDownloads[i].fileURL
                recentDownloads[i].fileURL = renamed
            }
        }
    }

    /// Restores the name the file was downloaded with.
    func undoTidy(_ id: UUID) {
        guard let i = recentDownloads.firstIndex(where: { $0.id == id }),
              let original = recentDownloads[i].originalFileURL,
              let restored = moveFile(recentDownloads[i].fileURL, toName: original.lastPathComponent) else { return }
        recentDownloads[i].fileURL = restored
        recentDownloads[i].originalFileURL = nil
    }

    /// Renames within the same folder, adding " (n)" if the name is taken.
    private func moveFile(_ source: URL, toName name: String) -> URL? {
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let dir = source.deletingLastPathComponent()
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var dest = dir.appendingPathComponent(name)
        var n = 2
        while fileManager.fileExists(atPath: dest.path), dest.standardizedFileURL != source.standardizedFileURL {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        do {
            try fileManager.moveItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Open the file in its default application.
    /// If the file was moved or deleted since downloading, drop it from the list.
    func open(_ item: DownloadItem) {
        guard fileManager.fileExists(atPath: item.fileURL.path) else {
            removeItem(id: item.id)
            return
        }
        NSWorkspace.shared.open(item.fileURL)
    }

    /// Reveal the file in Finder.
    func revealInFinder(_ item: DownloadItem) {
        guard fileManager.fileExists(atPath: item.fileURL.path) else {
            removeItem(id: item.id)
            return
        }
        NSWorkspace.shared.selectFile(item.fileURL.path, inFileViewerRootedAtPath: item.fileURL.deletingLastPathComponent().path)
    }

    /// Remove an item from the recent downloads list (does not delete the file on disk).
    func removeItem(_ item: DownloadItem) {
        DispatchQueue.main.async { [weak self] in
            self?.recentDownloads.removeAll { $0.id == item.id }
        }
    }

    /// Remove an item by id.
    func removeItem(id: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.recentDownloads.removeAll { $0.id == id }
        }
    }
}
