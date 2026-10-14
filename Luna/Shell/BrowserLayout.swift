import Foundation

/// Window layout. Sidebar is Arc-style; the rest mirror Helium's layouts.
enum BrowserLayout: String, CaseIterable, Identifiable {
    /// Vertical sidebar with spaces, pinned and today tabs.
    case sidebar
    /// One row: navigation, address field, tabs inline, toolbar icons.
    case compact
    /// Row 1: navigation, address field, icons. Row 2: tabs.
    case dynamic
    /// Row 1: tabs beside the window controls. Row 2: navigation, address field, icons.
    case classic

    static let defaultsKey = "luna_layout"

    var id: String { rawValue }

    /// Reads a stored value, mapping the pre-Helium "topTabs" layout to Classic.
    init(stored: String) {
        self = stored == "topTabs" ? .classic : (BrowserLayout(rawValue: stored) ?? .sidebar)
    }

    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .compact: return "Compact"
        case .dynamic: return "Dynamic"
        case .classic: return "Classic"
        }
    }

    var summary: String {
        switch self {
        case .sidebar: return "Vertical tabs, folders and spaces in a sidebar."
        case .compact: return "Address bar and tabs share a single row."
        case .dynamic: return "Address bar on top, tabs underneath."
        case .classic: return "Tabs on top, address bar underneath."
        }
    }
}

/// UserDefaults keys for window chrome options (Settings → Appearance).
enum ChromePrefs {
    static let centeredAddressBar = "luna_centered_address_bar"
    static let minimalURL = "luna_minimal_url"
    static let addressBarProgress = "luna_address_bar_progress"
    static let frameless = "luna_frameless"
    static let alwaysShowTopBar = "luna_frameless_always_show_top_bar"
    static let roundedFrame = "luna_rounded_frame"
    static let showHomeButton = "luna_show_home_button"
    static let hideWindowButtons = "luna_hide_window_buttons"
}
