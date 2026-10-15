import Foundation

/// The address bar's and start page's search engine (Settings → Search).
enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, brave, ecosia

    static let defaultsKey = "luna_search_engine"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .ecosia: return "Ecosia"
        }
    }

    private var base: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .duckduckgo: return "https://duckduckgo.com/?q="
        case .bing: return "https://www.bing.com/search?q="
        case .brave: return "https://search.brave.com/search?q="
        case .ecosia: return "https://www.ecosia.org/search?q="
        }
    }

    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: base + encoded)
    }
}
