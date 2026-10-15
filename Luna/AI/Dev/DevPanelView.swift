import AppKit
import SwiftUI

/// Dev mode: drive Claude Code or Codex in a project folder from the AI panel.
/// A setup bar (agent, project, model, resume, terminal), the streamed thread with tool and
/// approval cards, and a composer (⌘↩ sends, Esc stops). The session starts on the first send.
struct DevPanelView: View {
    let fontSize: CGFloat
    var onOpenSettings: () -> Void

    @AppStorage(DevPrefs.agentKey) private var agentRaw: String = AgentCLIKind.claudeCode.rawValue
    @AppStorage(DevPrefs.projectKey) private var projectPath: String = ""
    @AppStorage(DevPrefs.modelKey) private var model: String = ""
    @AppStorage(DevPrefs.resumeKey) private var resume: Bool = false
    @AppStorage(DevPrefs.terminalKey) private var terminalMode: Bool = false

    @State private var controller = DevSessionController.shared
    @State private var input = ""
    @State private var editorHeight: CGFloat = 36
    @State private var terminalGeneration = 0
    @FocusState private var inputFocused: Bool

    private var agent: AgentCLIKind { AgentCLIKind(rawValue: agentRaw) ?? .claudeCode }
    private var projectURL: URL? { projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath, isDirectory: true) }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTurnActive: Bool { controller.thread?.isTurnActive == true }

    var body: some View {
        VStack(spacing: 0) {
            setupBar
            HairlineDivider(opacity: 0.08)
            if terminalMode {
                terminalArea
            } else {
                threadArea
                composer
            }
        }
        .onAppear { if controller.installed.isEmpty { controller.refreshInstalled() } }
    }

    // MARK: - Setup bar

    private var setupBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                agentMenu
                projectMenu
                Spacer(minLength: 4)
                PanelIconButton(systemName: terminalMode ? "text.bubble" : "terminal",
                                help: terminalMode ? "Show thread" : "Show terminal (raw CLI)") { terminalMode.toggle() }
            }
            HStack(spacing: 6) {
                modelMenu
                Toggle(isOn: $resume) {
                    Text("Resume last").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Continue this project's last \(agent.displayName) session")
                Spacer(minLength: 4)
                statusText
            }
            if controller.isInstalled(agent) == false {
                installHint
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var agentMenu: some View {
        Menu {
            Picker("Agent", selection: Binding(get: { agent }, set: { switchAgent($0) })) {
                ForEach(AgentCLIKind.allCases, id: \.self) { kind in
                    Text(kind.displayName + (controller.isInstalled(kind) == false ? " (not installed)" : "")).tag(kind)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ChatMenuLabel(icon: "chevron.left.forwardslash.chevron.right", text: agent.displayName,
                           dimmed: controller.isInstalled(agent) == false)
        }
        .chatMenuStyle()
        .help("Coding agent")
        .accessibilityLabel("Agent: \(agent.displayName)")
    }

    private var projectMenu: some View {
        Menu {
            Button("Choose Folder…") { chooseFolder() }
            let recents = DevPrefs.recentProjects()
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Toggle((path as NSString).abbreviatingWithTildeInPath, isOn: Binding(
                            get: { path == projectPath }, set: { if $0 { selectProject(path) } }))
                    }
                }
            }
        } label: {
            ChatMenuLabel(icon: "folder", text: projectURL?.lastPathComponent ?? "Choose project",
                           dimmed: projectURL == nil)
        }
        .chatMenuStyle()
        .help(projectPath.isEmpty ? "Project folder" : (projectPath as NSString).abbreviatingWithTildeInPath)
        .accessibilityLabel("Project: \(projectURL?.lastPathComponent ?? "none")")
    }

    private var modelMenu: some View {
        let options = DevModelCatalog.models(for: agent)
        let current = options.first { $0.id == model }?.name ?? (model.isEmpty ? "Default model" : model)
        return Menu {
            Picker("Model", selection: Binding(get: { model }, set: { switchModel($0) })) {
                Text("Default").tag("")
                ForEach(options, id: \.id) { Text($0.name).tag($0.id) }
                if !model.isEmpty, !options.contains(where: { $0.id == model }) {
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ChatMenuLabel(icon: "cpu", text: current, dimmed: model.isEmpty)
        }
        .chatMenuStyle()
        .help("Model for the next session")
        .accessibilityLabel("Model: \(current)")
    }

    @ViewBuilder
    private var statusText: some View {
        if controller.isStarting {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Starting…")
            }
            .font(.system(size: 11))
            .foregroundStyle(ChatTokens.textSecondary)
        } else if let thread = controller.thread, thread.isAlive {
            HStack(spacing: 4) {
                Circle().fill(ChatTokens.accent).frame(width: 6, height: 6)
                Text(sessionSummary(thread))
            }
            .font(.system(size: 11))
            .foregroundStyle(ChatTokens.textSecondary)
            .help(controller.hasBrowserTools ? "This session can use Luna's browser tools" : "Session running")
            .accessibilityElement(children: .combine)
        }
    }

    private func sessionSummary(_ thread: DevThreadState) -> String {
        var parts = [thread.isTurnActive ? "Working" : "Ready"]
        if controller.hasBrowserTools { parts.append("browser tools") }
        if let cost = thread.sessionCostUSD { parts.append(String(format: "$%.3f", cost)) }
        return parts.joined(separator: " · ")
    }

    private var installHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.orange)
            Text("`\(agent.executableName)` not found. Install with ")
                + Text(DevModelCatalog.installCommand(agent)).font(.system(size: 11, design: .monospaced))
        }
        .font(.system(size: 11))
        .foregroundStyle(ChatTokens.textSecondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Terminal

    @ViewBuilder
    private var terminalArea: some View {
        if let projectURL, controller.isInstalled(agent) != false {
            DevTerminalView(kind: agent, projectDir: projectURL)
                .id("\(agent.rawValue)|\(projectPath)|\(terminalGeneration)")
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("\(agent.displayName) terminal")
        } else {
            centered(projectURL == nil
                     ? "Choose a project folder to open \(agent.executableName) in a terminal."
                     : "Install \(agent.executableName) to use the terminal.")
        }
    }

    // MARK: - Thread

    private var threadArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let thread = controller.thread {
                        ForEach(Array(thread.items.enumerated()), id: \.offset) { _, item in
                            itemView(item, thread: thread)
                        }
                        if thread.isTurnActive, !lastIsStreaming(thread), thread.pendingApprovals == 0 {
                            LunaSayingRow(fontSize: fontSize)
                        }
                    } else if !controller.isStarting {
                        emptyState
                    }
                    if let error = controller.startErrorText {
                        DevErrorView(message: error,
                                     detail: controller.startError == .notFound(agent.executableName)
                                     ? "Install: " + DevModelCatalog.installCommand(agent) : "", fontSize: fontSize)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: controller.thread?.items) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        ChatEmptyState(
            title: projectURL == nil ? "Choose a project" : "Code with \(agent.displayName)",
            subtitle: projectURL == nil
                ? "Pick the folder \(agent.displayName) should work in. It runs on this Mac with your own CLI login."
                : "Working in \((projectPath as NSString).abbreviatingWithTildeInPath). Commands and file edits ask first.",
            suggestions: projectURL == nil
                ? [ChatEmptyState.Suggestion(title: "Choose Folder…") { chooseFolder() }]
                : [
                    ChatEmptyState.Suggestion(title: "Explain this project") {
                        sendText("Give me a short overview of this project: what it does and how it is organized.")
                    },
                    ChatEmptyState.Suggestion(title: "Review uncommitted changes") {
                        sendText("Review the uncommitted changes in this repository for bugs.")
                    },
                    ChatEmptyState.Suggestion(title: "Open the terminal") { terminalMode = true },
                    ChatEmptyState.Suggestion(title: "Connect browser tools…", action: onOpenSettings),
                ]
        )
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(ChatTokens.textSecondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lastIsStreaming(_ thread: DevThreadState) -> Bool {
        if case .assistant(_, true)? = thread.items.last { return true }
        return false
    }

    @ViewBuilder
    private func itemView(_ item: DevThreadState.Item, thread: DevThreadState) -> some View {
        switch item {
        case .user(let text):
            PanelMessageRow(message: ChatMessage(role: .user, text: text), fontSize: fontSize)
        case .assistant(let text, _):
            PanelMessageRow(message: ChatMessage(role: .assistant, text: text), fontSize: fontSize,
                            onLinkTapped: { NSWorkspace.shared.open($0) })
        case .tool(let card):
            DevToolCardView(card: card)
        case .approval(let card):
            PanelApprovalCard(systemImage: Self.approvalIcon(card.request.kind),
                              title: Self.approvalTitle(card.request, agent: thread.kind),
                              summary: card.request.summary,
                              detail: DevApprovalText.detail(for: card.request),
                              state: Self.approvalState(card.status)) { decision in
                let d: CLIApprovalDecision = switch decision {
                case .allow: .allow
                case .allowForSession: .allowForSession
                case .deny: .deny
                }
                controller.respond(approvalID: card.request.id, decision: d)
            }
        case .turn(let footer):
            DevTurnFooterView(footer: footer, sessionCost: thread.sessionCostUSD)
        case .error(let message):
            ChatErrorBanner(message: message, fontSize: fontSize - 1)
        case .crash(let status, let signaled, let tail):
            DevErrorView(message: "\(thread.kind.displayName) quit unexpectedly (\(signaled ? "signal" : "exit") \(status)). Send a message to start a new session.",
                         detail: tail, fontSize: fontSize)
        }
    }

    static func approvalIcon(_ kind: CLIApprovalKind) -> String {
        switch kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .permission: return "lock.open"
        case .tool: return "wrench.and.screwdriver"
        }
    }

    static func approvalTitle(_ r: CLIApprovalRequest, agent: AgentCLIKind) -> String {
        switch r.kind {
        case .command: return "\(agent.displayName) wants to run a command"
        case .fileChange: return "\(agent.displayName) wants to edit files"
        case .permission: return "\(agent.displayName) wants more permissions"
        case .tool: return "\(agent.displayName) wants to use \(r.title)"
        }
    }

    static func approvalState(_ s: DevThreadState.ApprovalCard.Status) -> PanelApprovalCard.State {
        switch s {
        case .pending: return .pending
        case .expired: return .expired
        case .decided(let d):
            switch d {
            case .allow: return .decided("Allowed")
            case .allowForSession: return .decided("Allowed for this session")
            case .deny, .cancel: return .decided("Denied")
            }
        }
    }

    // MARK: - Composer

    private var canSend: Bool {
        guard !trimmedInput.isEmpty, projectURL != nil, !controller.isStarting else { return false }
        guard let thread = controller.thread, thread.isAlive else { return true } // a send starts a session
        return thread.canSend
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if isTurnActive, agent == .codex {
                Text("Codex takes the next message when this turn ends.")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatTokens.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
            }
            HStack(alignment: .bottom, spacing: 4) {
                PanelTextEditor(
                    text: $input,
                    placeholder: projectURL == nil ? "Choose a project first" : "Ask \(agent.displayName)…  ⌘↩ to send",
                    minHeight: 36,
                    fontSize: fontSize,
                    isFocused: $inputFocused,
                    onSubmit: send,
                    reportedHeight: $editorHeight,
                    submitOnReturn: false,
                    onEscape: {
                        guard isTurnActive else { return false }
                        controller.interrupt()
                        return true
                    },
                    accessibilityLabel: "Message to \(agent.displayName)"
                )
                .frame(maxWidth: .infinity)
                if isTurnActive {
                    composerButton("stop.fill", size: 12, enabled: true, help: "Stop (Esc)", label: "Stop",
                                   action: controller.interrupt)
                }
                if !isTurnActive || agent == .claudeCode {
                    composerButton("arrow.up", size: 14, enabled: canSend, help: "Send (⌘↩)", label: "Send",
                                   action: send)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .lunaGlass(cornerRadius: 22, interactive: true)
            .focusShadow(inputFocused)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.top, 4)
    }

    /// Same plain glyph buttons as the chat composer (ChatSendStopButton), without its Return shortcut.
    private func composerButton(_ symbol: String, size: CGFloat, enabled: Bool, help: String, label: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Color.white.opacity(enabled ? 0.9 : 0.3))
                .frame(width: 28, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(label)
    }

    // MARK: - Actions

    private func sendText(_ text: String) {
        input = text
        send()
    }

    private func send() {
        let text = trimmedInput
        guard canSend, let projectURL else { return }
        input = ""
        if controller.thread?.isAlive == true {
            controller.send(text)
            return
        }
        Task {
            await controller.start(kind: agent, projectDir: projectURL, model: model, resume: resume)
            if controller.thread?.isAlive == true { controller.send(text) } else { input = text }
        }
    }

    private func switchAgent(_ kind: AgentCLIKind) {
        guard kind != agent else { return }
        agentRaw = kind.rawValue
        model = ""
        controller.stop()
    }

    private func switchModel(_ id: String) {
        guard id != model else { return }
        model = id
        // The model is fixed per session; the next send starts a new one.
        if controller.thread != nil, !isTurnActive { controller.stop() }
    }

    private func selectProject(_ path: String) {
        guard path != projectPath else { return }
        DevPrefs.remember(project: path)
        projectPath = path
        controller.stop()
        terminalGeneration += 1
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the folder \(agent.displayName) works in"
        if let projectURL { panel.directoryURL = projectURL }
        if panel.runModal() == .OK, let url = panel.url {
            selectProject(url.path)
        }
    }
}

// MARK: - Models

/// The models offered in Dev mode's model menu, so nobody types a model ID.
enum DevModelCatalog {
    typealias Model = (id: String, name: String)

    /// Claude Code accepts these aliases for the current models.
    static let claudeModels: [Model] = [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]

    static func models(for kind: AgentCLIKind) -> [Model] {
        switch kind {
        case .claudeCode: return claudeModels
        case .codex: return codexModels()
        }
    }

    /// Codex keeps the models it offers in ~/.codex/models_cache.json; empty when it has not run yet.
    static func codexModels(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Model] {
        guard let data = try? Data(contentsOf: home.appending(path: ".codex/models_cache.json")) else { return [] }
        return parseCodexModels(data)
    }

    static func parseCodexModels(_ data: Data) -> [Model] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let list)? = root["models"] else { return [] }
        return list.compactMap { m in
            guard let slug = m["slug"]?.stringValue, m["visibility"]?.stringValue != "hide" else { return nil }
            return (slug, m["display_name"]?.stringValue ?? slug)
        }
    }

    static func installCommand(_ kind: AgentCLIKind) -> String {
        switch kind {
        case .claudeCode: return "npm install -g @anthropic-ai/claude-code"
        case .codex: return "npm install -g @openai/codex"
        }
    }
}

// MARK: - Cards

/// A tool call: name and one-line summary, status, output on demand.
private struct DevToolCardView: View {
    let card: DevThreadState.ToolCard
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if !card.output.isEmpty { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    ChatStatusIcon(state: status)
                    Text(card.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChatTokens.textPrimary)
                    Text(card.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ChatTokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !card.output.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ChatTokens.textTertiary)
                    }
                }
                .frame(minHeight: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(card.summary)
            .accessibilityLabel("\(card.name): \(card.summary), \(statusText)")
            .accessibilityHint(card.output.isEmpty ? "" : (expanded ? "Hides the output" : "Shows the output"))
            if expanded {
                ScrollView {
                    Text(card.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ChatTokens.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(.top, 6)
            }
        }
        .chatCard(padding: 8)
    }

    private var status: ChatStatusIcon.State {
        switch card.status {
        case .running: return .running
        case .done: return .done
        case .failed: return .failed
        }
    }

    private var statusText: String {
        switch card.status {
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

/// End of a turn: outcome, tokens and cost on one quiet line.
private struct DevTurnFooterView: View {
    let footer: DevThreadState.TurnFooter
    let sessionCost: Double?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9.5))
            Text(parts.joined(separator: " · ")).lineLimit(2)
        }
        .font(.system(size: 11))
        .foregroundStyle(isFailure ? ChatTokens.errorText : ChatTokens.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool { if case .failed = footer.outcome { return true }; return false }

    private var icon: String {
        switch footer.outcome {
        case .completed: "checkmark"
        case .interrupted: "stop.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var parts: [String] {
        var out: [String]
        switch footer.outcome {
        case .completed: out = ["Done"]
        case .interrupted: out = ["Interrupted"]
        case .failed(let message): out = ["Failed" + (message.map { ": \($0)" } ?? "")]
        }
        if let i = footer.inputTokens, let o = footer.outputTokens, i + o > 0 {
            out.append("\(i.formatted()) in / \(o.formatted()) out")
        }
        if let cost = footer.costUSD {
            var s = String(format: "$%.4f", cost)
            if let sessionCost, sessionCost > cost { s += String(format: " (session $%.4f)", sessionCost) }
            out.append(s)
        }
        return out
    }
}

/// An error with an optional monospaced tail (CLI stderr, install command).
private struct DevErrorView: View {
    let message: String
    let detail: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChatErrorBanner(message: message, fontSize: fontSize - 1)
            if !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.system(size: fontSize - 2.5, design: .monospaced))
                        .foregroundStyle(ChatTokens.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
            }
        }
    }
}
