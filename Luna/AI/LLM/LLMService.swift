import Foundation

/// Routes chat requests to the provider chosen in Settings → AI & Models.
/// Every AI surface (start page, side panel, Luna Max) goes through here.
final class LLMService {
    static let shared = LLMService()

    private let gemini = GeminiClient(apiKeyProvider: { KeychainManager.shared.fetchGeminiKey() })
    private let ollama = OllamaClient()

    nonisolated deinit {}

    var provider: AIProvider { AIProvider.current }

    /// The model the current provider will use, for display.
    var modelName: String {
        switch provider {
        case .chatgpt: return ModelPrefs.string(ModelPrefs.chatgptModel)
        case .openai: return ModelPrefs.string(ModelPrefs.openaiModel)
        case .anthropic: return ModelPrefs.string(ModelPrefs.anthropicModel, default: ModelPrefs.defaultAnthropicModel)
        case .gemini: return "gemini-2.5-flash"
        case .ollama: return ModelPrefs.string(ModelPrefs.ollamaModel)
        }
    }

    /// Streams a reply. Cancel the returned task to stop it; `onCompletion`
    /// is not called after cancellation.
    @discardableResult
    func stream(_ request: LLMRequest,
                onToken: @escaping (String) -> Void,
                onCompletion: @escaping (Result<Void, Error>) -> Void) -> Task<Void, Never> {
        switch provider {
        case .gemini:
            return gemini.generateStreaming(
                prompt: request.prompt, context: request.context,
                recentMessages: request.recentMessages, conversationSummary: request.conversationSummary,
                onToken: onToken, onCompletion: onCompletion)
        case .ollama:
            return ollama.generateStreaming(
                baseURLString: ModelPrefs.string(ModelPrefs.ollamaBaseURL, default: "http://127.0.0.1:11434"),
                model: ModelPrefs.string(ModelPrefs.ollamaModel),
                prompt: request.prompt, context: request.context,
                recentMessages: request.recentMessages, conversationSummary: request.conversationSummary,
                onToken: onToken, onCompletion: onCompletion)
        case .chatgpt, .openai, .anthropic:
            let provider = self.provider
            let model = modelName
            return Task {
                do {
                    switch provider {
                    case .chatgpt:
                        try await OpenAIResponsesClient(credential: .chatGPT).stream(model: model, request: request, onToken: onToken)
                    case .openai:
                        try await OpenAIResponsesClient(credential: .apiKey).stream(model: model, request: request, onToken: onToken)
                    default:
                        try await AnthropicClient().stream(model: model, request: request, onToken: onToken)
                    }
                    if !Task.isCancelled { onCompletion(.success(())) }
                } catch {
                    if !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                        onCompletion(.failure(error))
                    }
                }
            }
        }
    }

    /// Collects a full reply (titles, summaries, Luna Max).
    func complete(_ request: LLMRequest) async throws -> String {
        var text = ""
        var result: Result<Void, Error>?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            stream(request, onToken: { text += $0 }, onCompletion: { r in
                result = r
                cont.resume()
            })
        }
        if case .failure(let error) = result { throw error }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func complete(_ request: LLMRequest, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do { completion(.success(try await complete(request))) } catch { completion(.failure(error)) }
        }
    }

    /// 2-3 sentence summary used to keep long conversations within context.
    func summarize(_ messages: [ChatMessage], completion: @escaping (Result<String, Error>) -> Void) {
        let transcript = messages.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n")
        complete(LLMRequest(prompt: "Summarize this conversation in 2-3 sentences:\n\(transcript)\n\nReply with ONLY the summary."),
                 completion: completion)
    }
}
