// Luna — shared chat styling for the AI start page and the AI side panel.
// The start page is the reference design; the panel uses the same pieces.
import SwiftUI
import AppKit

// MARK: - Tokens

enum ChatTokens {
    static let textPrimary   = Color(white: 0.94)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary  = Color(white: 0.50)
    static let accent        = Color(red: 0.45, green: 0.58, blue: 0.72)
    static let errorText     = Color(red: 0.95, green: 0.55, blue: 0.55)
    static let surfaceElevated = Color(white: 0.14)
    static let cornerRadius: CGFloat  = 14
    static let barMaxWidth: CGFloat   = 680
    static let chatMaxWidth: CGFloat  = 720
}

// MARK: - Type

/// Luna's own voice: New York (the system serif) for the name, greetings and
/// titles. Body text and replies stay in the system font for readability.
enum LunaType {
    static func brand(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Surface

/// Dark under-window material with a near-opaque wash (the start page backdrop).
struct ChatSurfaceBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow, state: .active)
            startPageGlassTint.opacity(startPageGlassTintOpacity)
        }
    }
}

// MARK: - Thinking / errors

/// One progress line: pulsing dot while running, check when done.
struct ChatThinkingRow: View {
    let text: String
    var isComplete: Bool = false
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(ChatTokens.accent.opacity(0.7))
            } else {
                Circle()
                    .fill(ChatTokens.accent)
                    .frame(width: 6, height: 6)
                    .modifier(ChatPulse())
            }
            Text(text)
                .font(.system(size: fontSize - 1))
                .foregroundColor(Color.white.opacity(isComplete ? 0.4 : 0.6))
        }
    }
}

struct ChatErrorBanner: View {
    let message: String
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(ChatTokens.errorText)
            Text(message)
                .font(.system(size: fontSize))
                .foregroundColor(ChatTokens.errorText)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: ChatTokens.chatMaxWidth, alignment: .leading)
        .background(ChatTokens.errorText.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: ChatTokens.cornerRadius, style: .continuous))
        .accessibilityLabel("Error: \(message)")
    }
}

// MARK: - Composer buttons

/// Plain arrow to send, square to stop (the start page composer).
struct ChatSendStopButton: View {
    let isSending: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        if isSending {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.8))
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop")
            .accessibilityLabel("Stop generating")
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.white.opacity(canSend ? 0.9 : 0.3))
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [])
            .help("Send (↩)")
            .accessibilityLabel("Send message")
        }
    }
}

/// "+" for adding tabs or files to the conversation.
struct ChatAddContextButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(ChatTokens.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(isActive ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Add tabs or files")
        .accessibilityLabel("Add context")
    }
}

struct ChatPulse: ViewModifier {
    @State private var scale: CGFloat = 0.85

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    scale = 1.15
                }
            }
    }
}

// MARK: - Bubble

/// Chat message: user text in a soft bubble (edit on hover), assistant
/// replies as rich text with retry / copy underneath.

struct LunaChatBubble: View {
    let message: ChatMessage
    let isUser: Bool
    let fontSize: CGFloat
    var onRetry: (() -> Void)?
    var onEdit: (() -> Void)?
    var onLinkTapped: ((URL) -> Void)?

    private let userBubbleColor = Color.white.opacity(0.15)
    private let linkColor = Color(red: 0.4, green: 0.6, blue: 1.0)
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 48) }
                bubbleContent
                if !isUser { Spacer(minLength: 48) }
            }
            actionRow
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            HStack(alignment: .bottom, spacing: 6) {
                if isHovered, let onEdit = onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.5))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                userTextView
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(userBubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
        } else {
            RichMessageView(
                rawText: message.text,
                fontSize: fontSize,
                linkColor: linkColor,
                onLinkTapped: onLinkTapped
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @State private var showCopied: Bool = false

    @ViewBuilder
    private var actionRow: some View {
        if !isUser {
            HStack(spacing: 4) {
                if let onRetry = onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(isHovered ? 0.6 : 0.35))
                            .frame(width: 24, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: copyToClipboard) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(showCopied ? 0.7 : (isHovered ? 0.6 : 0.35)))
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.15)) { showCopied = false }
        }
    }

    private var userTextView: some View {
        Group {
            if let attr = userMarkdown {
                Text(attr)
            } else {
                Text(message.text)
            }
        }
        .font(.system(size: fontSize))
        .foregroundColor(Color.white.opacity(0.95))
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .lineSpacing(5)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var userMarkdown: AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard var attributed = try? AttributedString(markdown: message.text, options: options, baseURL: nil) else {
            return try? AttributedString(markdown: message.text)
        }
        for run in attributed.runs {
            if run.link != nil {
                attributed[run.range].foregroundColor = linkColor
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }
}

