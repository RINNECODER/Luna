import Foundation

/// Window layout: Arc-style vertical sidebar, or classic horizontal tabs on top.
enum BrowserLayout: String, CaseIterable, Identifiable {
    case sidebar
    case topTabs

    static let defaultsKey = "luna_layout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .topTabs: return "Top Tabs"
        }
    }
}
