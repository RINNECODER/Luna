import SwiftUI

/// Settings → AI & Models: choose a provider, sign in or add a key, pick a model.
struct ModelsSettingsView: View {
    @AppStorage(AIProvider.defaultsKey) private var providerRaw: String = AIProvider.gemini.rawValue

    private var provider: Binding<AIProvider> {
        Binding(get: { AIProvider(rawValue: providerRaw) ?? .gemini }, set: { providerRaw = $0.rawValue })
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: provider) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                Text(provider.wrappedValue.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            switch provider.wrappedValue {
            case .chatgpt: ChatGPTSection()
            case .anthropic: AnthropicSection()
            case .openai: OpenAISection()
            case .gemini: GeminiSection()
            case .ollama: OllamaSection()
            }

            ComputerUseSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - ChatGPT

private struct ChatGPTSection: View {
    @ObservedObject private var auth = ChatGPTAuth.shared
    @AppStorage(ModelPrefs.chatgptModel) private var model = ""
    @State private var error: String?

    var body: some View {
        Section("ChatGPT account") {
            if let creds = auth.credentials {
                LabeledContent("Signed in as") {
                    Text(creds.email.isEmpty ? (creds.name ?? "ChatGPT user") : creds.email)
                }
                Button("Sign Out", role: .destructive) {
                    Task {
                        let revoked = await auth.signOut()
                        error = revoked ? nil : "Signed out on this Mac. OpenAI didn't confirm revoking access; you can disconnect Luna in ChatGPT settings."
                    }
                }
            } else if auth.isSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { auth.cancelSignIn() }
                }
            } else {
                Button("Sign in with ChatGPT") {
                    error = nil
                    Task {
                        do { try await auth.signIn() } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Text("Requires ChatGPT Plus or Pro. Requests count against your plan, up to a weekly limit you set in ChatGPT. Luna never sees your password or your ChatGPT conversations.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if auth.isSignedIn {
            Section("Model") {
                ModelPicker(selection: $model) {
                    try await OpenAIResponsesClient(credential: .chatGPT).listModels().map { ($0.id, $0.displayName) }
                }
            }
        }
    }
}

// MARK: - API-key providers

private struct AnthropicSection: View {
    @AppStorage(ModelPrefs.anthropicModel) private var model = ModelPrefs.defaultAnthropicModel

    var body: some View {
        Section("Anthropic API key") {
            APIKeyField(account: .anthropicKey, placeholder: "sk-ant-…")
            Link("Get an API key from the Claude Console", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            Text("Anthropic doesn't offer sign-in for other apps, so Luna uses an API key. Usage is billed to your Console account.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section("Model") {
            ModelPicker(selection: $model) {
                try await AnthropicClient().listModels().map { ($0.id, $0.displayName) }
            }
        }
    }
}

private struct OpenAISection: View {
    @AppStorage(ModelPrefs.openaiModel) private var model = ""

    var body: some View {
        Section("OpenAI API key") {
            APIKeyField(account: .openAIKey, placeholder: "sk-…")
            Link("Get an API key from the OpenAI platform", destination: URL(string: "https://platform.openai.com/api-keys")!)
        }
        Section("Model") {
            ModelPicker(selection: $model) {
                try await OpenAIResponsesClient(credential: .apiKey).listModels().map { ($0.id, $0.displayName) }
            }
        }
    }
}

private struct GeminiSection: View {
    var body: some View {
        Section("Gemini API key") {
            APIKeyField(account: .geminiKey, placeholder: "AIza…")
            Link("Get an API key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
        }
    }
}

private struct OllamaSection: View {
    @AppStorage(ModelPrefs.ollamaBaseURL) private var baseURL = "http://127.0.0.1:11434"
    @AppStorage(ModelPrefs.ollamaModel) private var model = ""

    var body: some View {
        Section("Ollama") {
            TextField("Server", text: $baseURL, prompt: Text("http://127.0.0.1:11434"))
                .autocorrectionDisabled()
            ModelPicker(selection: $model) {
                try await withCheckedThrowingContinuation { cont in
                    OllamaClient().listModels(baseURLString: baseURL) { result in
                        cont.resume(with: result.map { $0.sorted().map { ($0, $0) } })
                    }
                }
            }
            .id(baseURL)
        }
    }
}

// MARK: - Computer use

/// Agent mode (`/agent <goal>` in the AI panel). Uses Jev when a TypeSafe key is saved,
/// otherwise the provider above picks each step.
private struct ComputerUseSection: View {
    @AppStorage(JevClient.modelDefaultsKey) private var model = JevClient.defaultModel

    var body: some View {
        Section("Computer use (Jev)") {
            APIKeyField(account: .typesafeKey, placeholder: "TypeSafe API key")
            TextField("Model", text: $model, prompt: Text(JevClient.defaultModel))
                .autocorrectionDisabled()
            Text("Type /agent followed by a goal in the AI panel to let Luna operate the current tab. With a TypeSafe key, Jev picks each step; without one, the model above does. Typed values always come from the model above.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared rows

/// Secure field that saves to the Keychain; shows a masked state once stored.
private struct APIKeyField: View {
    let account: KeychainManager.Account
    let placeholder: String

    @State private var input = ""
    @State private var hasKey = false
    @State private var status: String?

    var body: some View {
        Group {
            if hasKey {
                LabeledContent("API key") {
                    HStack {
                        Text("Saved in Keychain").foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            try? KeychainManager.shared.delete(account)
                            hasKey = false
                        }
                    }
                }
            } else {
                HStack {
                    SecureField("API key", text: $input, prompt: Text(placeholder))
                    Button("Save") {
                        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            try KeychainManager.shared.store(key, for: account)
                            input = ""
                            hasKey = true
                            status = nil
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let status { Text(status).font(.callout).foregroundStyle(.red) }
        }
        .onAppear { hasKey = KeychainManager.shared.data(for: account) != nil }
    }
}

/// Model pop-up filled from the provider's model list, with a refresh button.
/// Keeps the current selection visible even if the list hasn't loaded.
private struct ModelPicker: View {
    @Binding var selection: String
    let load: () async throws -> [(id: String, name: String)]

    @State private var models: [(id: String, name: String)] = []
    @State private var loading = false
    @State private var error: String?

    private var options: [(id: String, name: String)] {
        if selection.isEmpty || models.contains(where: { $0.id == selection }) { return models }
        return [(selection, selection)] + models
    }

    var body: some View {
        HStack {
            Picker("Model", selection: $selection) {
                if selection.isEmpty { Text("Choose a model").tag("") }
                ForEach(options, id: \.id) { Text($0.name).tag($0.id) }
            }
            Button {
                Task { await refresh() }
            } label: {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("Refresh models")
            .disabled(loading)
        }
        .task { await refresh() }
        if let error {
            Text(error).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            models = try await load()
            error = models.isEmpty ? "No models available." : nil
            if selection.isEmpty, let first = models.first { selection = first.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
