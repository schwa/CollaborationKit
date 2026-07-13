import CollaborationKit
import SwiftUI

/// A `Section` with a `SecureField` for an API key plus Save/Clear controls,
/// backed by a slot in ``CollaborationCredentials``. `Footer` is a
/// `@ViewBuilder` so hosts can pass a rich footer without paying the
/// `AnyView` tax.
///
/// Two convenience wrappers ship (``AnthropicAPIKeySection`` and
/// ``OpenAIAPIKeySection``); use them unless you're wiring a custom slot.
public struct APIKeySection<Footer: View>: View {
    @Environment(CollaborationCredentials.self)
    private var credentials

    public let title: LocalizedStringKey
    public let placeholder: LocalizedStringKey
    let read: (any CredentialStore) -> CredentialReadResult
    let write: (any CredentialStore, String) -> Bool
    @ViewBuilder let footer: () -> Footer

    @State private var key: String = ""
    @State private var savedFlash: Bool = false
    @State private var readError: String?
    @State private var saveError: String?

    public init(
        title: LocalizedStringKey,
        placeholder: LocalizedStringKey,
        read: @escaping (any CredentialStore) -> CredentialReadResult,
        write: @escaping (any CredentialStore, String) -> Bool,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.placeholder = placeholder
        self.read = read
        self.write = write
        self.footer = footer
    }

    public var body: some View {
        Section {
            keyRow
            statusRow
        } header: {
            Text(title)
        } footer: {
            footer()
        }
    }

    private var keyRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                SecureField(placeholder, text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                    .onSubmit(save)
                    .onAppear(perform: load)
                Button("Clear") {
                    key = ""
                    save()
                }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        } label: {
            Text("API Key")
        }
    }

    @ViewBuilder private var statusRow: some View {
        if savedFlash || readError != nil || saveError != nil {
            HStack {
                if savedFlash {
                    Text("Saved")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .transition(.opacity)
                }
                if let readError {
                    Text(readError).foregroundStyle(.red).font(.callout)
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red).font(.callout)
                }
                Spacer()
            }
            .animation(.smooth, value: savedFlash)
        }
    }

    private func load() {
        switch read(credentials.store) {
        case .found(let value):
            key = value
            readError = nil

        case .notFound:
            key = ""
            readError = nil

        case .failed(let status):
            readError = "Couldn't read the saved key (\(CredentialReadResult.message(for: status))). Try reopening Settings."
        }
    }

    private func save() {
        let ok = write(credentials.store, key)
        if ok {
            saveError = nil
            savedFlash = true
            credentials.refresh()
            Task {
                try? await Task.sleep(for: .seconds(2))
                savedFlash = false
            }
        } else {
            saveError = "Couldn't save to Keychain."
        }
    }
}

/// Section for the Anthropic (billed) API key.
public struct AnthropicAPIKeySection: View {
    public init() {}
    public var body: some View {
        APIKeySection(
            title: "Anthropic API",
            placeholder: "sk-ant-…",
            read: { $0.anthropicAPIKey() },
            write: { $0.saveAnthropicAPIKey($1) },
            footer: {
                Link(
                    "Get an API key from the Claude Console",
                    destination: URL(string: "https://console.anthropic.com/settings/keys")!
                )
                .font(.callout)
            }
        )
    }
}

/// Section for the OpenAI API key. Also works for OpenAI-compatible servers
/// where the value is ignored (LM Studio, Ollama, etc.).
public struct OpenAIAPIKeySection: View {
    public init() {}
    public var body: some View {
        APIKeySection(
            title: "OpenAI API",
            placeholder: "sk-…",
            read: { $0.openAIAPIKey() },
            write: { $0.saveOpenAIAPIKey($1) },
            footer: {
                Link(
                    "Get an API key from the OpenAI platform",
                    destination: URL(string: "https://platform.openai.com/api-keys")!
                )
                .font(.callout)
            }
        )
    }
}

#Preview("Anthropic key") {
    Form { AnthropicAPIKeySection() }
        .formStyle(.grouped)
        .environment(CollaborationCredentials(initialBackend: .anthropicAPI))
        .frame(width: 480, height: 260)
}
