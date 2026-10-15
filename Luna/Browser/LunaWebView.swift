// Luna — WKWebView subclass that makes the context menu's download items work.
import AppKit
import WebKit

/// WebKit's built-in "Download Image", "Download Linked File" and "Download
/// Video/Audio" menu items do nothing unless the app handles them, so Luna
/// retargets them: find what was right-clicked, then start a download for it.
final class LunaWebView: WKWebView {
    /// Called with the URL to download and the page it came from.
    var onDownloadRequest: ((URL) -> Void)?

    private enum Target: String {
        case image, link, media
    }

    /// Right-click location in CSS pixels, captured when the menu opens.
    private var menuPoint: CGPoint = .zero

    private static let menuTargets: [String: Target] = [
        "WKMenuItemIdentifierDownloadImage": .image,
        "WKMenuItemIdentifierDownloadLinkedFile": .link,
        "WKMenuItemIdentifierDownloadMedia": .media,
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let p = convert(event.locationInWindow, from: nil)
        let scale = max(0.01, pageZoom * magnification)
        menuPoint = CGPoint(x: p.x / scale, y: (isFlipped ? p.y : bounds.height - p.y) / scale)
        for item in menu.items {
            guard let raw = item.identifier?.rawValue, let target = Self.menuTargets[raw] else { continue }
            item.target = self
            item.action = #selector(downloadFromMenu(_:))
            item.representedObject = target.rawValue
        }
    }

    @objc private func downloadFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let target = Target(rawValue: raw) else { return }
        let script = """
        const el = document.elementFromPoint(x, y);
        if (!el) return null;
        if (kind === "link") { const a = el.closest("a[href]"); return a ? a.href : null; }
        if (kind === "media") { const m = el.closest("video, audio"); return m ? (m.currentSrc || m.src) : null; }
        const img = el.closest("img") || (el.querySelector && el.querySelector("img"));
        if (img) return img.currentSrc || img.src;
        const bg = getComputedStyle(el).backgroundImage.match(/url\\(["']?(.*?)["']?\\)/);
        return bg ? new URL(bg[1], document.baseURI).href : null;
        """
        callAsyncJavaScript(script, arguments: ["x": menuPoint.x, "y": menuPoint.y, "kind": target.rawValue],
                            in: nil, in: .defaultClient) { [weak self] result in
            guard case .success(let value) = result, let string = value as? String,
                  let url = URL(string: string) else { return }
            self?.onDownloadRequest?(url)
        }
    }
}
