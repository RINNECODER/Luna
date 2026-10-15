import AppKit
import Foundation
import WebKit

/// One tab as the tools see it.
struct AgentTabInfo: Equatable {
    let id: UUID
    let title: String
    let url: String
    let active: Bool
}

/// The tabs a toolbox drives: a browser window (`ProfileSessionHost`) or a test stub.
protocol AgentBrowserHost: AnyObject {
    var tabs: [AgentTabInfo] { get }
    var activeTabId: UUID? { get }
    /// The tab's page, creating and loading its web view if needed. Nil for an empty tab.
    func webView(for tab: UUID) -> WKWebView?
    /// Opens and activates a tab loading `url`.
    func openTab(url: URL) -> UUID
    func selectTab(_ id: UUID)
    func navigate(_ tab: UUID, to url: URL)
}

enum LunaToolError: LocalizedError, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .invalidArguments(let m), .unavailable(let m): return m
        }
    }
}

/// What a tool returns. `text` has already been through `AgentRedaction`.
struct LunaToolResult: Equatable {
    var text: String
    var isError: Bool
}

/// One parameter of a tool. The JSON Schema and argument validation both come from these.
struct LunaToolParam {
    enum Kind: String { case string, integer }
    let name: String
    let kind: Kind
    let description: String
    var required = true
    /// Lets a required string be empty (e.g. clearing a field).
    var allowsEmpty = false
    var allowed: [String]? = nil
    var range: ClosedRange<Int>? = nil
}

/// A tool callable by Luna's own agent panel and, over MCP, by outside agents.
struct LunaTool {
    let name: String
    let description: String
    let params: [LunaToolParam]
    /// Mutating tools ask the user before an outside agent may call them.
    let mutates: Bool
    /// Adds an optional `tab_id` parameter; `LunaToolCall.tab()` resolves it.
    var targetsTab = true
    let run: (LunaToolCall) async throws -> String

    static let tabParam = LunaToolParam(name: "tab_id", kind: .string,
                                        description: "Tab id from tabs_list. Defaults to the active tab; another tab is brought to the front.",
                                        required: false)

    var allParams: [LunaToolParam] { targetsTab ? params + [Self.tabParam] : params }

    var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for p in allParams {
            var prop: [String: JSONValue] = ["type": .string(p.kind.rawValue), "description": .string(p.description)]
            if let allowed = p.allowed { prop["enum"] = .array(allowed.map(JSONValue.string)) }
            if let range = p.range {
                prop["minimum"] = .number(Double(range.lowerBound))
                prop["maximum"] = .number(Double(range.upperBound))
            }
            properties[p.name] = .object(prop)
        }
        return .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(allParams.filter(\.required).map { .string($0.name) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// Checks names, presence, types, enums and ranges against `params`.
    func validate(_ arguments: [String: JSONValue]) throws {
        let byName = Dictionary(uniqueKeysWithValues: allParams.map { ($0.name, $0) })
        if let unknown = arguments.keys.sorted().first(where: { byName[$0] == nil }) {
            throw LunaToolError.invalidArguments("\(name): unknown argument '\(unknown)'.")
        }
        for p in allParams {
            guard let value = arguments[p.name], value != .null else {
                if p.required { throw LunaToolError.invalidArguments("\(name): '\(p.name)' is required.") }
                continue
            }
            switch p.kind {
            case .string:
                guard let s = value.stringValue else {
                    throw LunaToolError.invalidArguments("\(name): '\(p.name)' must be a string.")
                }
                if p.required, !p.allowsEmpty, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw LunaToolError.invalidArguments("\(name): '\(p.name)' must not be empty.")
                }
                if let allowed = p.allowed, !allowed.contains(s) {
                    throw LunaToolError.invalidArguments("\(name): '\(p.name)' must be one of \(allowed.joined(separator: ", ")).")
                }
            case .integer:
                guard let n = value.numberValue, n == n.rounded(), abs(n) < 1e9 else {
                    throw LunaToolError.invalidArguments("\(name): '\(p.name)' must be an integer.")
                }
                if let range = p.range, !range.contains(Int(n)) {
                    throw LunaToolError.invalidArguments("\(name): '\(p.name)' must be \(range.lowerBound)–\(range.upperBound).")
                }
            }
        }
    }
}

/// The arguments of one call plus access to the browser, for a tool's `run`.
struct LunaToolCall {
    let arguments: [String: JSONValue]
    let host: AgentBrowserHost

    func string(_ key: String) -> String? { arguments[key]?.stringValue }
    func int(_ key: String) -> Int? { arguments[key]?.numberValue.map { Int($0) } }

    /// The `tab_id` tab (brought to the front) or the active tab.
    func tab() throws -> UUID {
        if let raw = string("tab_id") {
            guard let id = UUID(uuidString: raw), host.tabs.contains(where: { $0.id == id }) else {
                throw LunaToolError.invalidArguments("No tab with id \(raw). Call tabs_list.")
            }
            if host.activeTabId != id { host.selectTab(id) }
            return id
        }
        guard let id = host.activeTabId else { throw LunaToolError.unavailable("No tab is open.") }
        return id
    }

    /// The page driver for the target tab; shared with the agent loop so action ids carry over.
    func driver() throws -> PageDriver {
        guard let webView = host.webView(for: try tab()) else {
            throw LunaToolError.unavailable("This tab has no page yet. Use navigate first.")
        }
        return LunaToolbox.driver(for: webView)
    }

    /// An http(s) URL with a host; same rule as the AI panel's browser actions.
    func url(_ key: String) throws -> URL {
        let raw = (string(key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: normalized), isSafeBrowserURL(url) else {
            throw LunaToolError.invalidArguments("Only http and https URLs can be opened.")
        }
        return url
    }
}

/// The one tool layer: Luna's `/agent` panel and the MCP bridge both go through it.
/// Tools are listed in `LunaTools.all` (LunaTools.swift); adding a tool is a change there only.
final class LunaToolbox {
    let tools: [LunaTool]
    private let hostProvider: () -> AgentBrowserHost?

    nonisolated deinit {}

    init(tools: [LunaTool] = LunaTools.all, host: @escaping () -> AgentBrowserHost?) {
        self.tools = tools
        self.hostProvider = host
    }

    func tool(named name: String) -> LunaTool? { tools.first { $0.name == name } }

    /// Runs a tool. Unknown names throw; bad arguments and tool failures come back as
    /// `isError` results so a model can correct itself. All output is redacted here.
    func call(_ name: String, arguments: [String: JSONValue]) async throws -> LunaToolResult {
        guard let tool = tool(named: name) else { throw LunaToolError.unknownTool(name) }
        do {
            try tool.validate(arguments)
            guard let host = hostProvider() else { throw LunaToolError.unavailable("No Luna browser window is open.") }
            let text = try await tool.run(LunaToolCall(arguments: arguments, host: host))
            return LunaToolResult(text: AgentRedaction.redact(text), isError: false)
        } catch {
            return LunaToolResult(text: AgentRedaction.redact(error.localizedDescription), isError: true)
        }
    }

    // MARK: Shared page drivers

    /// One driver per web view, so ids from a snapshot taken by one caller stay valid for the next.
    private static let drivers = NSMapTable<WKWebView, PageDriver>.weakToStrongObjects()

    static func driver(for webView: WKWebView) -> PageDriver {
        if let driver = drivers.object(forKey: webView) { return driver }
        let driver = PageDriver(webView: webView)
        drivers.setObject(driver, forKey: webView)
        return driver
    }

    /// The computer-use agent on a tab, for the AI panel's `/agent` and the `run_task` tool.
    static func agent(for webView: WKWebView, maxSteps: Int = AgentPrompts.maxSteps) -> ComputerUseAgent {
        ComputerUseAgent.make(driver: driver(for: webView), maxSteps: maxSteps)
    }

    // MARK: Formatting

    /// Element table plus page text, as tools return it.
    static func describe(_ snap: PageSnapshot) -> String {
        var lines = ["Title: \(snap.title)", "URL: \(snap.url)",
                     "Scroll: \(Int(snap.scroll.y)) of \(Int(snap.scroll.height))", "",
                     "Actions (\(snap.actions.count)\(snap.omittedActions > 0 ? ", \(snap.omittedActions) more not shown" : "")):"]
        for a in snap.actions {
            var row = "\(a.id)\t\(a.kind)\t\(a.label)"
            if let role = a.role { row += "\t[\(role)]" }
            if a.kind == "fill", let v = a.value, !v.isEmpty { row += "\tvalue=\"\(v)\"" }
            if a.kind == "select", let v = a.currentValue, !v.isEmpty { row += "\tcurrent=\"\(v)\"" }
            if let c = a.checked { row += "\tchecked=\(c)" }
            lines.append(row)
        }
        lines += ["", "Text:", snap.text]
        return AgentRedaction.redact(lines.joined(separator: "\n"))
    }

    /// Waits (bounded) for a navigation started on `webView` to begin, so the next
    /// snapshot sees the new page rather than the old one.
    static func waitForNavigationStart(_ webView: WKWebView, from oldURL: URL?, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !webView.isLoading, webView.url == oldURL, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Same rule as `CommandRouter`'s browser actions: http(s) with a host.
func isSafeBrowserURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    return url.host != nil
}
