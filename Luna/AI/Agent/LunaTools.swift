import Foundation
import WebKit

/// Every tool Luna exposes to its own agent panel and, over MCP, to outside agents.
/// To add a tool, append a `LunaTool` here: the MCP `tools/list`, argument validation,
/// redaction and approval (set `mutates`) all follow from the entry.
enum LunaTools {
    static let all: [LunaTool] = [
        tabsList, tabOpen, tabSelect, navigate, snapshot, click, type, select, scroll, read, runTask,
    ]

    static let tabsList = LunaTool(
        name: "tabs_list", description: "List open Luna tabs: id, title, URL, and which is active.",
        params: [], mutates: false, targetsTab: false
    ) { call in
        let tabs = call.host.tabs
        if tabs.isEmpty { return "No tabs." }
        return tabs.map { "\($0.active ? "*" : " ") \($0.id.uuidString)\t\($0.title.isEmpty ? "(untitled)" : $0.title)\t\($0.url)" }
            .joined(separator: "\n")
    }

    static let tabOpen = LunaTool(
        name: "tab_open", description: "Open an http(s) URL in a new tab, make it active, and return its id and a snapshot.",
        params: [LunaToolParam(name: "url", kind: .string, description: "http or https URL")],
        mutates: true, targetsTab: false
    ) { call in
        let url = try call.url("url")
        let id = call.host.openTab(url: url)
        guard let webView = call.host.webView(for: id) else { return "Opened tab \(id.uuidString)." }
        await LunaToolbox.waitForNavigationStart(webView, from: nil)
        let snap = try await LunaToolbox.driver(for: webView).snapshot()
        return "Opened tab \(id.uuidString).\n\n" + LunaToolbox.describe(snap)
    }

    static let tabSelect = LunaTool(
        name: "tab_select", description: "Bring a tab to the front.",
        params: [LunaToolParam(name: "id", kind: .string, description: "Tab id from tabs_list")],
        mutates: false, targetsTab: false
    ) { call in
        let raw = call.string("id") ?? ""
        guard let id = UUID(uuidString: raw), call.host.tabs.contains(where: { $0.id == id }) else {
            throw LunaToolError.invalidArguments("No tab with id \(raw). Call tabs_list.")
        }
        call.host.selectTab(id)
        return "Selected tab \(id.uuidString)."
    }

    static let navigate = LunaTool(
        name: "navigate", description: "Load an http(s) URL in the tab and return a snapshot of the new page.",
        params: [LunaToolParam(name: "url", kind: .string, description: "http or https URL")],
        mutates: true
    ) { call in
        let url = try call.url("url")
        let tab = try call.tab()
        let oldURL = call.host.webView(for: tab)?.url
        call.host.navigate(tab, to: url)
        guard let webView = call.host.webView(for: tab) else { throw LunaToolError.unavailable("The tab could not load.") }
        await LunaToolbox.waitForNavigationStart(webView, from: oldURL)
        return LunaToolbox.describe(try await LunaToolbox.driver(for: webView).snapshot())
    }

    static let snapshot = LunaTool(
        name: "snapshot",
        description: "Observe the page: a table of actionable elements (ids like e3 for click/type/select) and the visible text. Take one before acting; ids expire when the page changes.",
        params: [], mutates: false
    ) { call in
        LunaToolbox.describe(try await call.driver().snapshot())
    }

    static let click = LunaTool(
        name: "click", description: "Click an element by id from the latest snapshot. Returns a fresh snapshot.",
        params: [LunaToolParam(name: "id", kind: .string, description: "Action id, e.g. e3")],
        mutates: true
    ) { call in
        LunaToolbox.describe(try await call.driver().click(call.string("id") ?? ""))
    }

    static let type = LunaTool(
        name: "type", description: "Replace the text of a field (a 'fill' id from the latest snapshot). Returns a fresh snapshot.",
        params: [LunaToolParam(name: "id", kind: .string, description: "Fill action id, e.g. e2"),
                 LunaToolParam(name: "text", kind: .string, description: "Text to enter", allowsEmpty: true)],
        mutates: true
    ) { call in
        LunaToolbox.describe(try await call.driver().type(call.string("id") ?? "", text: call.string("text") ?? ""))
    }

    static let select = LunaTool(
        name: "select",
        description: "Choose a dropdown option. Pass the option's own select id, or any option id of that dropdown plus the option's label or value.",
        params: [LunaToolParam(name: "id", kind: .string, description: "Select action id from the latest snapshot"),
                 LunaToolParam(name: "option", kind: .string, description: "Option label or value", required: false)],
        mutates: true
    ) { call in
        let driver = try call.driver()
        let id = call.string("id") ?? ""
        var target = id
        if let option = call.string("option")?.trimmingCharacters(in: .whitespaces), !option.isEmpty {
            guard let snap = driver.lastSnapshot, let base = snap.action(id: id), base.kind == "select" else {
                throw AgentError.stalePage("No select action \(id) in the last snapshot. Take a snapshot first.")
            }
            let wanted = option.lowercased()
            let match = snap.actions.first { a in
                a.kind == "select" && a.node == base.node &&
                    (a.value?.lowercased() == wanted || a.label.lowercased().hasSuffix("→ " + wanted))
            }
            if let match {
                target = match.id
            } else if base.currentValue?.lowercased() == wanted {
                return "'\(option)' is already selected."
            } else {
                throw LunaToolError.invalidArguments("No option '\(option)' in that dropdown.")
            }
        }
        return LunaToolbox.describe(try await driver.select(target))
    }

    static let scroll = LunaTool(
        name: "scroll", description: "Scroll the page one screen up or down. Returns a fresh snapshot.",
        params: [LunaToolParam(name: "direction", kind: .string, description: "up or down", allowed: ["up", "down"])],
        mutates: false
    ) { call in
        LunaToolbox.describe(try await call.driver().scroll(down: call.string("direction") == "down"))
    }

    static let read = LunaTool(
        name: "read", description: "Return the page's visible text (secrets masked).",
        params: [], mutates: false
    ) { call in
        try await call.driver().read()
    }

    static let runTask = LunaTool(
        name: "run_task",
        description: "Let Luna's own computer-use agent (Jev, or the chat model set in Luna) carry out a goal on the tab. Returns the step log and the outcome.",
        params: [LunaToolParam(name: "goal", kind: .string, description: "What to accomplish on this page"),
                 LunaToolParam(name: "max_steps", kind: .integer, description: "Action budget (default 60)",
                               required: false, range: 1...AgentPrompts.maxSteps)],
        mutates: true
    ) { call in
        let tab = try call.tab()
        guard let webView = call.host.webView(for: tab) else {
            throw LunaToolError.unavailable("This tab has no page yet. Use navigate first.")
        }
        let agent = LunaToolbox.agent(for: webView, maxSteps: call.int("max_steps") ?? AgentPrompts.maxSteps)
        var lines: [String] = []
        var outcome: AgentOutcome = .cancelled
        for await event in agent.run(goal: call.string("goal") ?? "") {
            if let line = event.panelLine { lines.append(line) }
            if case .finished(let o, _, _) = event { outcome = o }
        }
        let log = lines.joined(separator: "\n")
        if case .failed(let why) = outcome { throw LunaToolError.unavailable("\(log)\n\nFailed: \(why)") }
        return log
    }
}
