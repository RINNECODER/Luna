import SwiftUI

/// Where each provider's model choice lives and how to list its models.
/// Shared by Settings and the AI panel's model menu, so neither asks for a typed model ID.
enum ModelCatalog {
    typealias Model = (id: String, name: String)

    /// The defaults key for the provider's model, or nil when it has a fixed model (Gemini).
    static func modelKey(for provider: AIProvider) -> String? {
        switch provider {
        case .chatgpt: return ModelPrefs.chatgptModel
        case .anthropic: return ModelPrefs.anthropicModel
        case .openai: return ModelPrefs.openaiModel
        case .gemini: return nil
        case .ollama: return ModelPrefs.ollamaModel
        }
    }

    static func load(_ provider: AIProvider) async throws -> [Model] {
        switch provider {
        case .chatgpt:
            return try await OpenAIResponsesClient(credential: .chatGPT).listModels().map { ($0.id, $0.displayName) }
        case .anthropic:
            return try await AnthropicClient().listModels().map { ($0.id, $0.displayName) }
        case .openai:
            return try await OpenAIResponsesClient(credential: .apiKey).listModels().map { ($0.id, $0.displayName) }
        case .gemini:
            return [(LLMService.shared.modelName, LLMService.shared.modelName)]
        case .ollama:
            let base = ModelPrefs.string(ModelPrefs.ollamaBaseURL, default: "http://127.0.0.1:11434")
            return try await withCheckedThrowingContinuation { cont in
                OllamaClient().listModels(baseURLString: base) { result in
                    cont.resume(with: result.map { $0.sorted().map { ($0, $0) } })
                }
            }
        }
    }
}

/// The composer's model menu: the provider and its models, picked from lists.
struct PanelModelMenu: View {
    @AppStorage(AIProvider.defaultsKey) private var providerRaw: String = AIProvider.gemini.rawValue
    @State private var models: [AIProvider: [ModelCatalog.Model]] = [:]
    @State private var loadError: [AIProvider: String] = [:]
    @State private var currentModel = LLMService.shared.modelName
    var onOpenSettings: () -> Void

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .gemini }

    var body: some View {
        Menu {
            Section(provider.displayName) {
                if let list = models[provider], !list.isEmpty {
                    ForEach(list, id: \.id) { m in
                        Toggle(m.name, isOn: Binding(
                            get: { m.id == currentModel },
                            set: { if $0 { select(m.id) } }
                        ))
                    }
                } else if let error = loadError[provider] {
                    Text(error)
                } else {
                    Text("Loading models…")
                }
            }
            Menu("Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button("Model Settings…", action: onOpenSettings)
        } label: {
            // The header's model line, as before, now opening the model list.
            HStack(spacing: 3) {
                Text(headerLabel).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .chatMenuStyle()
        .help("Choose the model")
        .accessibilityLabel("Model: \(label)")
        .task(id: providerRaw) {
            currentModel = LLMService.shared.modelName
            await load(provider)
        }
    }

    private var label: String {
        let model = currentModel
        if model.isEmpty { return provider.displayName }
        return models[provider]?.first(where: { $0.id == model })?.name ?? model
    }

    private var headerLabel: String {
        currentModel.isEmpty ? provider.displayName : "\(provider.displayName) · \(label)"
    }

    private func select(_ id: String) {
        guard let key = ModelCatalog.modelKey(for: provider) else { return }
        UserDefaults.standard.set(id, forKey: key)
        currentModel = id
    }

    private func load(_ p: AIProvider) async {
        do {
            let list = try await ModelCatalog.load(p)
            models[p] = list
            loadError[p] = list.isEmpty ? "No models available" : nil
        } catch {
            loadError[p] = "Can't list models. Check Settings."
        }
    }
}
