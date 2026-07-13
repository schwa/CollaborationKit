import SwiftUI
import CollaborationKit

/// A `Section` that shows a `SecureField` for an API key and Save/Clear
/// controls, backed by a slot in ``CollaborationCredentials``.
///
/// Two convenience wrappers are provided (``AnthropicAPIKeySection`` and
/// ``OpenAIAPIKeySection``); use them unless you're wiring a custom slot.
public struct APIKeySection: View {
    @Environment(CollaborationCredentials.self) private var credentials

    /// User-visible section header (e.g. "Anthropic API Key").
    public let title: LocalizedStringKey

    /// Placeholder shown in the empty field.
    public let placeholder: LocalizedStringKey

    /// Optional footer content — typically a `Link` to where the key comes
    /// from ("Get an API key from the Claude Console" and similar).
    public let footer: AnyView?

    /// Reads the current value from the store.
    let read: (KeychainCredentialStore) -> KeychainReadResult

    /// Writes a value (empty deletes) to the store.
    let write: (KeychainCredentialStore, String) -> Bool

    @State private var key: String = ""
    @State private var savedFlash: Bool = false
    @State private var readError: String?
    @State private var saveError: String?

    /// Creates a fully-custom section. Prefer the named wrappers for the
    /// standard slots.
    public init(
        title: LocalizedStringKey,
        placeholder: LocalizedStringKey,
        footer: AnyView? = nil,
        read: @escaping (KeychainCredentialStore) -> KeychainReadResult,
        write: @escaping (KeychainCredentialStore, String) -> Bool
    ) {
        self.title = title
        self.placeholder = placeholder
        self.footer = footer
        self.read = read
        self.write = write
    }

    public var body: some View {
        Section {
            SecureField(placeholder, text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .onAppear(perform: load)

            HStack {
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                Button("Clear") {
                    key = ""
                    save()
                }
                if savedFlash {
                    Text("Saved")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .transition(.opacity)
                }
                if let readError {
                    Text(readError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
            }
        } header: {
            Text(title)
        } footer: {
            if let footer {
                footer
            }
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
            // Don't clobber the field on a transient failure — leave whatever
            // the user has typed and surface the reason.
            readError = "Couldn't read the saved key (\(KeychainReadResult.message(for: status))). Try reopening Settings."
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
            title: "Anthropic API Key",
            placeholder: "sk-ant-…",
            footer: AnyView(
                Link("Get an API key from the Claude Console",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.callout)
            ),
            read: { $0.anthropicAPIKey() },
            write: { $0.saveAnthropicAPIKey($1) }
        )
    }
}

/// Section for the OpenAI API key. Also works for OpenAI-compatible servers
/// where the value is ignored (LM Studio, Ollama, etc.).
public struct OpenAIAPIKeySection: View {
    public init() {}
    public var body: some View {
        APIKeySection(
            title: "OpenAI API Key",
            placeholder: "sk-…",
            footer: AnyView(
                Link("Get an API key from the OpenAI platform",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.callout)
            ),
            read: { $0.openAIAPIKey() },
            write: { $0.saveOpenAIAPIKey($1) }
        )
    }
}
