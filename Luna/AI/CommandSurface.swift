// Luma MVP - AI Side Panel (redesigned for clarity, calmness, accessibility)
import Foundation
import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import Combine

/// Right-side AI command panel (Cmd+E toggle). Per-tab chat with history.
///
/// Redesign: clear hierarchy (header → context → conversation → input),
/// calm visuals, WCAG contrast, keyboard + screen reader support.
struct CommandSurfaceView: View {
    @Binding var isPresented: Bool
    @Binding var messages: [ChatMessage]
    let webViewWrapper: WebViewWrapper
    let commandRouter: CommandRouter
    let gemini: GeminiClient
    let ollama: OllamaClient
    let historyManager: HistoryManager
    let onActionProposed: (LLMResponse) -> Void
    
    var tabId: UUID? = nil
    /// Other panes of this tab's split view: always part of the context.
    var splitPeers: [UUID] = []

    @AppStorage("luma_ai_panel_font_size") private var aiPanelFontSizeRaw: Int = 13
    @AppStorage("luma_ai_provider") private var aiProviderRaw: String = AIProvider.gemini.rawValue
    @AppStorage("luma_ollama_base_url") private var ollamaBaseURL: String = "http://127.0.0.1:11434"
    @AppStorage("luma_ollama_model") private var ollamaModel: String = ""
    @State private var inputText: String = ""
    @State private var errorMessage: String? = nil
    @State private var isSending: Bool = false
    @State private var actionProposedMessage: String? = nil
    @State private var conversationSummary: String? = nil
    @State private var lastSummarizedMessageCount: Int = 0
    /// Active streaming task — cancel to stop generation.
    @State private var streamingTask: Task<Void, Never>? = nil
    /// Incremented whenever a stream starts or is cancelled; stale callbacks compare
    /// their captured generation against this and bail out.
    @State private var streamGeneration: Int = 0
    @FocusState private var isInputFocused: Bool

    @State private var pageTitle: String? = nil
    @State private var pageText: String? = nil
    @State private var isLoadingContext: Bool = false

    @State private var attachedDocuments: [AttachedDocument] = []
    @State private var documentPickerPresented: Bool = false
    @State private var documentError: String? = nil
    @State private var includeCurrentTab: Bool = true // Current tab is always included initially
    @State private var includedOtherTabIds: [UUID] = []
    @State private var otherTabContexts: [UUID: (title: String?, text: String?)] = [:]
    @State private var addContextPresented: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var currentTabChipId: UUID = UUID()

    /// Tracks the editor's current natural height so the outer container can match it without any fixed frame.
    @State private var editorContentHeight: CGFloat = 36

    private let minInputHeight: CGFloat = 36

    private var chatFontSize: CGFloat { CGFloat(aiPanelFontSizeRaw) }

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .gemini
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader()
            conversationStream()
            inputArea()
        }
        // No surface of its own: the panel sits on the window chrome, like the
        // sidebar, so the browser, the page and the panel read as one piece.
        .environment(\.colorScheme, .dark)
        .overlay { if isDropTargeted { FileDropHint() } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDocumentDrop(providers: providers)
        }
        // Load page context only when the sidebar is toggled open (not on every URL change).
        // Auto-reloading on navigation can look like automated scraping to strict sites (e.g. Akamai).
        .onAppear {
            restoreConversationSummary()
            loadPageContext()
            includeSplitPeers()
        }
        .onChange(of: splitPeers) { _, _ in includeSplitPeers() }
        // Parent can remove the panel (tab switch / close) without calling close();
        // cancel the stream so orphaned tasks don't keep mutating state.
        .onDisappear {
            streamGeneration += 1
            streamingTask?.cancel()
            streamingTask = nil
            isSending = false
        }
        .fileImporter(
            isPresented: $documentPickerPresented,
            allowedContentTypes: [UTType.pdf, .plainText, .utf8PlainText, .commaSeparatedText, .xml, .html],
            allowsMultipleSelection: true
        ) { result in
            documentError = nil
            switch result {
            case .success(let urls):
                for url in urls {
                    addDocument(from: url, securityScoped: true)
                }
            case .failure(let error):
                documentError = error.localizedDescription
            }
        }
    }

    // MARK: - Header (minimal - note icon for new chat, close button)

    private func panelHeader() -> some View {
        HStack(spacing: 6) {
            PanelIconButton(systemName: "square.and.pencil", help: "New Chat", action: startNewChat)
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text("Luna")
                    .font(LunaType.brand(size: 15))
                Text(modelLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            PanelIconButton(systemName: "xmark", help: "Close (Esc)", action: close)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var modelLabel: String {
        let service = LLMService.shared
        let model = service.modelName
        return model.isEmpty ? service.provider.displayName : "\(service.provider.displayName) · \(model)"
    }

    private func startNewChat() {
        streamingTask?.cancel()
        streamingTask = nil
        isSending = false
        messages = []
        attachedDocuments = []
        includeCurrentTab = true
        includedOtherTabIds = []
        otherTabContexts = [:]
        inputText = ""
        errorMessage = nil
        actionProposedMessage = nil
        conversationSummary = nil
        lastSummarizedMessageCount = 0
        editorContentHeight = minInputHeight
        loadPageContext() // Reload current page context
    }

    private func thisPageLabel() -> String {
        if let title = pageTitle, !title.isEmpty { return title }
        if let host = webViewWrapper.currentURL?.host { return host }
        return "Loading…"
    }

    // MARK: - Conversation stream

    private func conversationStream() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty {
                        emptyConversationState()
                    } else {
                        ForEach(messages) { msg in
                            LunaChatBubble(
                                message: msg,
                                isUser: msg.role == .user,
                                fontSize: chatFontSize,
                                onLinkTapped: { url in openLinkInNewTab(url) }
                            )
                            .id(msg.id)
                            .frame(maxWidth: ChatTokens.chatMaxWidth, alignment: msg.role == .user ? .trailing : .leading)
                        }
                        if isSending {
                            loadingIndicator()
                        }
                        if let err = errorMessage {
                            errorInlineView(message: err)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    /// Mirrors the start page: the moon, a quiet title, and capsule suggestions.
    private func emptyConversationState() -> some View {
        VStack(spacing: 0) {
            AsciiMoon(diameter: 92, isBusy: isSending)
                .padding(.bottom, 2)
            Text("Ask about this page")
                .font(LunaType.brand(size: 22))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.bottom, 8)
            Text("Summarize, explain, or find anything, with this page and any tabs or files you add as context.")
                .font(.system(size: 12))
                .foregroundColor(ChatTokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
            VStack(spacing: 6) {
                ForEach(["Summarize this page", "What are the key takeaways?", "Explain this simply"], id: \.self) { suggestion in
                    Button {
                        inputText = suggestion
                        sendCommand()
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(ChatTokens.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .contain)
    }

    private func loadingIndicator() -> some View {
        LunaSayingRow(fontSize: chatFontSize)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Assistant is thinking")
    }

    private func errorInlineView(message: String) -> some View {
        ChatErrorBanner(message: message, fontSize: chatFontSize)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Input area
    //
    // Glass rounded-rect box (start page style). Grows to show all typed text.
    // No internal scrolling — you always see everything before sending.

    private func inputArea() -> some View {
        VStack(spacing: 6) {
            if let documentError {
                Text(documentError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            // Context chips
            if includeCurrentTab || !includedOtherTabIds.isEmpty || !attachedDocuments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if includeCurrentTab {
                            ContextChip(kind: .page(url: webViewWrapper.currentURL, faviconURL: tabId.flatMap { webViewWrapper.faviconURLByTab[$0] ?? nil }),
                                        title: thisPageLabel(),
                                        onRemove: { includeCurrentTab = false })
                        }
                        ForEach(includedOtherTabIds, id: \.self) { otherId in
                            ContextChip(kind: .tab(url: webViewWrapper.tabManager?.tabURL[otherId] ?? nil,
                                                   faviconURL: webViewWrapper.faviconURLByTab[otherId] ?? nil),
                                        title: otherTabLabel(tabId: otherId),
                                        onRemove: { removeIncludedOtherTab(id: otherId) })
                        }
                        ForEach(attachedDocuments) { doc in
                            ContextChip(kind: .document(filename: doc.displayName),
                                        title: doc.displayName,
                                        onRemove: { removeAttachedDocument(id: doc.id) })
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 28)
            }

            HStack(alignment: .bottom, spacing: 4) {
                ChatAddContextButton(isActive: addContextPresented) { addContextPresented.toggle() }
                .popover(isPresented: $addContextPresented, arrowEdge: .top) {
                    AddContextPopover(
                        tabs: otherTabItems,
                        included: Set(includedOtherTabIds),
                        onToggleTab: toggleIncludedTab,
                        onChooseFiles: {
                            addContextPresented = false
                            documentPickerPresented = true
                        }
                    )
                }
                .padding(.bottom, 3)

                GrowingTextEditor(
                    text: $inputText,
                    placeholder: "Ask anything…",
                    minHeight: minInputHeight,
                    fontSize: chatFontSize,
                    isFocused: $isInputFocused,
                    onSubmit: sendCommand,
                    reportedHeight: $editorContentHeight
                )
                .frame(maxWidth: .infinity)

                ChatSendStopButton(
                    isSending: isSending,
                    canSend: !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    onSend: sendCommand,
                    onStop: stopStreaming
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .lunaGlass(cornerRadius: 22, interactive: true)
            .focusShadow(isInputFocused)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Message input")
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.top, 4)
    }

    /// Open tabs other than this one, for the "+" popover.
    private var otherTabItems: [AddContextPopover.TabItem] {
        guard let tm = webViewWrapper.tabManager else { return [] }
        return tm.tabOrder.filter { $0 != tabId }.compactMap { id in
            guard let url = tm.tabURL[id] ?? nil, url.scheme?.hasPrefix("http") == true else { return nil }
            return AddContextPopover.TabItem(id: id, title: otherTabLabel(tabId: id), url: url,
                                             faviconURL: webViewWrapper.faviconURLByTab[id] ?? nil)
        }
    }

    /// Split view: every pane's page is context, alongside this one.
    private func includeSplitPeers() {
        for id in splitPeers where !includedOtherTabIds.contains(id) {
            includedOtherTabIds.append(id)
            loadTabContext(for: id)
        }
    }

    private func toggleIncludedTab(_ id: UUID) {
        if includedOtherTabIds.contains(id) {
            removeIncludedOtherTab(id: id)
        } else {
            includedOtherTabIds.append(id)
            loadTabContext(for: id)
        }
    }

    private func openLinkInNewTab(_ url: URL) {
        // Only allow web schemes; model-generated markdown could contain
        // javascript:/file:/data: links which must never navigate the browser.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        if let tabManager = webViewWrapper.tabManager {
            let newTabId = tabManager.newTab(url: url)
            webViewWrapper.load(url: url, in: newTabId)
        }
    }

    /// Extracts text on a background task: PDF parsing can take seconds and
    /// must not block the main thread. The background task owns the security
    /// scope so sandboxed file access stays valid for the duration of the read.
    private func addDocument(from url: URL, securityScoped: Bool = false) {
        guard DocumentTextExtractor.isSupported(url) else {
            documentError = "Unsupported format. Use PDF, TXT, MD, JSON, CSV, XML, or HTML."
            return
        }
        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                if securityScoped {
                    guard url.startAccessingSecurityScopedResource() else { return nil }
                }
                defer {
                    if securityScoped { url.stopAccessingSecurityScopedResource() }
                }
                return DocumentTextExtractor.extractText(from: url)
            }.value
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                documentError = "Could not read text from “\(url.lastPathComponent)”."
                return
            }
            attachedDocuments.append(AttachedDocument(displayName: url.lastPathComponent, extractedText: text, fileURL: url))
            documentError = nil
        }
    }

    private func removeAttachedDocument(id: UUID) {
        attachedDocuments.removeAll { $0.id == id }
    }

    private func handleDocumentDrop(providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let u = url else { return }
                DispatchQueue.main.async { addDocument(from: u) }
            }
        }
        return true
    }

    private func close() {
        streamingTask?.cancel()
        streamingTask = nil
        isPresented = false
        inputText = ""
        errorMessage = nil
        isSending = false
        actionProposedMessage = nil
        attachedDocuments = []
        includeCurrentTab = true
        editorContentHeight = minInputHeight
    }

    /// Loads page context (title + visible text) when panel appears.
    private func loadPageContext() {
        isLoadingContext = true
        let group = DispatchGroup()

        group.enter()
        webViewWrapper.evaluatePageTitle { title in
            pageTitle = title
            group.leave()
        }

        group.enter()
        webViewWrapper.evaluateVisibleText(maxChars: 4000) { text in
            pageText = text
            group.leave()
        }

        group.notify(queue: .main) {
            isLoadingContext = false
        }
    }
    
    /// Loads page context (title + visible text) for a specific tab.
    private func loadTabContext(for tabId: UUID) {
        let group = DispatchGroup()
        var loadedTitle: String? = nil
        var loadedText: String? = nil

        group.enter()
        webViewWrapper.evaluatePageTitle(for: tabId) { title in
            loadedTitle = title
            group.leave()
        }

        group.enter()
        webViewWrapper.evaluateVisibleText(for: tabId, maxChars: 4000) { text in
            loadedText = text
            group.leave()
        }

        group.notify(queue: .main) {
            otherTabContexts[tabId] = (title: loadedTitle, text: loadedText)
        }
    }

    /// Builds context string from enabled context sources (current tab + attached files).
    private func buildContextString() -> String? {
        var parts: [String] = []

        // Include current tab context if enabled
        if includeCurrentTab {
            if let url = webViewWrapper.currentURL {
                parts.append("URL: \(url.absoluteString)")
            }
            if let title = pageTitle, !title.isEmpty {
                parts.append("Title: \(title)")
            }
            if let text = pageText, !text.isEmpty {
                parts.append("Page content:\n\(text)")
            }
        }

        // Include other tabs (same format as current tab: URL + title + page content)
        if let tm = webViewWrapper.tabManager {
            for id in includedOtherTabIds {
                if let url = tm.tabURL[id] ?? nil {
                    var tabParts: [String] = []
                    tabParts.append("URL: \(url.absoluteString)")
                    let context = otherTabContexts[id]
                    if let title = context?.title, !title.isEmpty {
                        tabParts.append("Title: \(title)")
                    } else if let t = tm.tabTitle[id], !t.isEmpty {
                        tabParts.append("Title: \(t)")
                    }
                    if let text = context?.text, !text.isEmpty {
                        tabParts.append("Page content:\n\(text)")
                    }
                    parts.append(tabParts.joined(separator: "\n"))
                }
            }
        }

        // Include attached documents
        for doc in attachedDocuments {
            parts.append("Document \"\(doc.displayName)\":\n\(doc.textForContext)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func otherTabLabel(tabId: UUID) -> String {
        guard let tm = webViewWrapper.tabManager else { return "Tab" }
        if let title = tm.tabTitle[tabId], !title.isEmpty { return title }
        if let url = tm.tabURL[tabId] ?? nil, let host = url.host { return host }
        return "Tab"
    }

    private func removeIncludedOtherTab(id: UUID) {
        includedOtherTabIds.removeAll { $0 == id }
        otherTabContexts.removeValue(forKey: id)
    }

    private func sendCommand() {
        // A send while a stream is active would corrupt message indices; require Stop first.
        guard !isSending else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let goal = Self.agentGoal(in: trimmed) {
            runAgent(goal: goal, command: trimmed)
            return
        }

        if let tabManager = webViewWrapper.tabManager,
           let response = commandRouter.proposal(for: trimmed, tabManager: tabManager) {
            messages.append(ChatMessage(role: .user, text: trimmed))
            messages.append(ChatMessage(role: .assistant, text: response.text))
            inputText = ""
            onActionProposed(response)
            return
        }

        isSending = true
        errorMessage = nil
        actionProposedMessage = nil

        let userMsg = ChatMessage(
            role: .user,
            text: trimmed,
            pageURL: webViewWrapper.currentURL?.absoluteString,
            pageTitle: pageTitle
        )
        messages.append(userMsg)
        inputText = ""

        let context = buildContextString()
        proceedWithStreaming(prompt: trimmed, context: context)
    }

    /// `/agent <goal>` runs the computer-use agent on this tab.
    static func agentGoal(in input: String) -> String? {
        guard input.lowercased().hasPrefix("/agent ") else { return nil }
        let goal = input.dropFirst("/agent ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? nil : goal
    }

    /// Streams each agent step into one assistant message. Stop cancels the run.
    private func runAgent(goal: String, command: String) {
        guard let webView = tabId.flatMap(webViewWrapper.webViewIfLoaded) ?? webViewWrapper.activeWebView else {
            errorMessage = "Open a page in this tab first."
            return
        }
        isSending = true
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: command,
                                    pageURL: webViewWrapper.currentURL?.absoluteString, pageTitle: pageTitle))
        inputText = ""
        let agent = ComputerUseAgent.make(webView: webView)
        let usesJev = agent.policy is JevPolicy
        let reply = ChatMessage(role: .assistant,
                                text: "Agent (\(usesJev ? JevClient.configuredModel : LLMService.shared.modelName)): \(goal)\n",
                                pageURL: webViewWrapper.currentURL?.absoluteString, pageTitle: pageTitle)
        messages.append(reply)
        let replyId = reply.id
        streamGeneration += 1
        let generation = streamGeneration
        streamingTask = Task {
            for await event in agent.run(goal: goal) {
                guard generation == streamGeneration,
                      let line = event.panelLine,
                      let idx = messages.firstIndex(where: { $0.id == replyId }) else { continue }
                messages[idx].text += "\n" + line
            }
            guard generation == streamGeneration else { return }
            isSending = false
            streamingTask = nil
        }
    }

    private func stopStreaming() {
        // Invalidate the current stream generation so late onToken/onCompletion
        // callbacks from the cancelled task are ignored.
        streamGeneration += 1
        streamingTask?.cancel()
        streamingTask = nil
        isSending = false
        // Mark partial response with a notice if there's content
        if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
            if !messages[lastIdx].text.isEmpty {
                messages[lastIdx].text += "\n\n*[Generation stopped]*"
            } else {
                messages.removeLast()
            }
        }
    }

    private func proceedWithStreaming(prompt: String, context: String?) {
        let recentContext = Array(messages.dropLast().suffix(6))

        // Append placeholder for assistant response
        let placeholder = ChatMessage(
            role: .assistant,
            text: "",
            pageURL: webViewWrapper.currentURL?.absoluteString,
            pageTitle: pageTitle
        )
        messages.append(placeholder)
        // Track by stable message id (indices go stale when messages are
        // removed/edited) and by generation (stale callbacks after Stop must not run).
        let placeholderId = placeholder.id
        streamGeneration += 1
        let generation = streamGeneration

        let onToken: (String) -> Void = { token in
            guard generation == streamGeneration,
                  let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
            messages[idx].text += token
        }

        let onCompletion: (Result<Void, Error>) -> Void = { result in
            guard generation == streamGeneration else { return }
            isSending = false
            streamingTask = nil
            switch result {
            case .success:
                checkAndSummarize()
            case .failure(let error):
                let msg = error.localizedDescription
                errorMessage = msg
                if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                    if messages[idx].text.isEmpty {
                        messages[idx].text = "Error: \(msg)"
                    } else {
                        messages[idx].text += "\n\n*[Error: \(msg)]*"
                    }
                }
            }
        }

        streamingTask = LLMService.shared.stream(
            LLMRequest(prompt: prompt, context: context, recentMessages: recentContext, conversationSummary: conversationSummary),
            onToken: onToken,
            onCompletion: onCompletion
        )
    }
    
    private func checkAndSummarize() {
        // Auto-summarize every 8 messages (4 exchanges)
        let messagesToSummarize = messages.count - lastSummarizedMessageCount
        
        if messagesToSummarize >= 8 {
            let messagesToProcess = Array(messages.suffix(messagesToSummarize))
            // Capture the summarized span now: messages can grow while the
            // summarize request is in flight, which would corrupt the range.
            let summarizedUpTo = messages.count

            let completion: (Result<String, Error>) -> Void = { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let summary):
                        // Append to existing summary or create new one
                        if let existing = conversationSummary {
                            conversationSummary = "\(existing)\n\nRecent: \(summary)"
                        } else {
                            conversationSummary = summary
                        }
                        lastSummarizedMessageCount = summarizedUpTo

                        // Save summary to history if we have a tab ID
                        if let tabId = tabId {
                            let summaryObj = ConversationSummary(
                                tabId: tabId,
                                summary: summary,
                                messageRange: (summarizedUpTo - messagesToSummarize)...(summarizedUpTo - 1)
                            )
                            historyManager.addConversationSummary(tabId: tabId, summary: summaryObj)
                        }
                        
                    case .failure:
                        // Silently fail - summarization is optimization, not critical
                        break
                    }
                }
            }
            LLMService.shared.summarize(messagesToProcess, completion: completion)
        }
    }

    private func restoreConversationSummary() {
        guard let tabId else { return }
        let summaries = historyManager.getSummariesForTab(tabId: tabId)
        conversationSummary = summaries.last?.summary
        lastSummarizedMessageCount = summaries.last.map { $0.messageRange.upperBound + 1 } ?? 0
    }
}

// MARK: - GrowingTextEditor
//
// Height comes from the NSTextView's own layout manager — no invisible Text
// mirror, no PreferenceKey. The NSTextView reports its content height after
// every keystroke; the SwiftUI frame follows.

private struct GrowingTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat
    var fontSize: CGFloat = 13
    @FocusState.Binding var isFocused: Bool
    var onSubmit: (() -> Void)? = nil
    @Binding var reportedHeight: CGFloat

    @State private var textHeight: CGFloat = 36

    private var font: Font { .system(size: fontSize) }
    private let placeholderColor = Color(nsColor: .placeholderTextColor)

    var body: some View {
        ZStack(alignment: .topLeading) {
            MultilineTextField(
                text: $text,
                fontSize: fontSize,
                dynamicHeight: $textHeight,
                minHeight: minHeight,
                onSubmit: onSubmit
            )
            .focused($isFocused)

            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundColor(placeholderColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: textHeight)
        .onChange(of: textHeight) { _, h in reportedHeight = h }
        .onAppear { reportedHeight = textHeight }
        .animation(.easeOut(duration: 0.15), value: textHeight)
    }
}

// MARK: - MultilineTextField (NSTextView wrapper)
//
// Reports its own content height via `dynamicHeight` using the layout manager.
// No internal scrolling — the view always shows all text.

private struct MultilineTextField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    @Binding var dynamicHeight: CGFloat
    var minHeight: CGFloat
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tv = BorderedTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        tv.defaultParagraphStyle = paragraphStyle
        tv.typingAttributes[.paragraphStyle] = paragraphStyle
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = tv
        context.coordinator.textView = tv

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(tv)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? BorderedTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        tv.onSubmit = onSubmit
        tv.font = .systemFont(ofSize: fontSize)
        if let container = tv.textContainer {
            let w = scrollView.contentSize.width
            if w > 0 {
                container.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
            }
        }
        // Defer height recalculation so we don't write @Binding during a view update
        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(tv)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextField
        weak var textView: BorderedTextView?

        init(_ parent: MultilineTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer,
                  let manager = textView.layoutManager else { return }
            manager.ensureLayout(for: container)
            let usedRect = manager.usedRect(for: container)
            let inset = textView.textContainerInset
            let newHeight = usedRect.height + inset.height * 2
            let clamped = max(parent.minHeight, newHeight)
            if abs(clamped - parent.dynamicHeight) > 0.5 {
                parent.dynamicHeight = clamped
            }
        }
    }
}

private class BorderedTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isKeypadEnter = event.keyCode == 76
        let isSubmitKey = (isReturn || isKeypadEnter) && !event.modifierFlags.contains(.shift)

        if isSubmitKey {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Allow Cmd+A, Cmd+C, Cmd+V, Cmd+X to work
        if event.modifierFlags.contains(.command) {
            return super.performKeyEquivalent(with: event)
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Attached documents (upload for AI context)

private struct AttachedDocument: Identifiable {
    let id: UUID
    let displayName: String
    let extractedText: String
    let fileURL: URL?

    init(id: UUID = UUID(), displayName: String, extractedText: String, fileURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.extractedText = extractedText
        self.fileURL = fileURL
    }

    /// Max chars per document in context to avoid token overflow.
    static let maxCharsInContext: Int = 12_000

    var textForContext: String {
        if extractedText.count <= Self.maxCharsInContext { return extractedText }
        return String(extractedText.prefix(Self.maxCharsInContext)) + "\n\n[Document truncated for length.]"
    }
}


// MARK: - Document text extraction

private enum DocumentTextExtractor {
    nonisolated static let supportedExtensions: Set<String> = ["pdf", "txt", "md", "json", "csv", "xml", "html"]

    nonisolated static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            return doc.string
        case "txt", "md", "json", "csv", "xml", "html":
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .utf16))
        default:
            return nil
        }
    }

    nonisolated static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
