// Luma MVP - Download manager and hub
import Foundation
import SwiftUI
import AppKit
import Combine

/// A single recent download for the hub.
struct DownloadItem: Identifiable {
    let id: UUID
    let url: URL
    var fileURL: URL
    let suggestedFilename: String
    let date: Date
    /// Set after Luna Max renamed the file; used for one-click undo.
    var originalFileURL: URL?
    var isTidying = false

    var displayName: String { fileURL.lastPathComponent }

    init(id: UUID = UUID(), url: URL, fileURL: URL, suggestedFilename: String, date: Date = Date()) {
        self.id = id
        self.url = url
        self.fileURL = fileURL
        self.suggestedFilename = suggestedFilename
        self.date = date
    }
}

/// Manages recent downloads; files are saved to ~/Downloads.
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var recentDownloads: [DownloadItem] = []
    private let maxRecent = 50
    private let fileManager = FileManager.default

    var downloadsDirectory: URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    private init() {}

    /// Call when a file was saved to path (from WKDownload or URLSession).
    func addDownload(url: URL, fileURL: URL, suggestedFilename: String) {
        let item = DownloadItem(url: url, fileURL: fileURL, suggestedFilename: suggestedFilename)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recentDownloads.insert(item, at: 0)
            if self.recentDownloads.count > self.maxRecent {
                self.recentDownloads.removeLast()
            }
            if LunaMaxPrefs.isOn(LunaMaxPrefs.tidyDownloads) { self.tidy(item.id) }
        }
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
