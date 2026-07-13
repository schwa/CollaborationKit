import SwiftUI
import CollaborationKit

/// A `Section` with a `SecureField` for an API key plus Save/Clear controls,
/// backed by a slot in ``CollaborationCredentials``. `Footer` is a
/// `@ViewBuilder` so hosts can pass a rich footer without paying the
/// `AnyView` tax.
///
/// Two convenience wrappers ship (``AnthropicAPIKeySection`` and
/// ``OpenAIAPIKeySection``); use them unless you're wiring a custom slot.
public struct APIKeySection<Footer: View>: View {
    @Environment(CollaborationCredentials.self) private var credentials

    public let title: LocalizedStringKey
    public let placeholder: LocalizedStringKey
    let read: (KeychainCredentialStore) -> KeychainReadResult
    let write: (KeychainCredentialStore, String) -> Bool
    @ViewBuilder let footer: () -> Footer

    @State private var key: String = ""
    @State private var savedFlash: Bool = false
    @State private var readError: String?
    @State private var saveError: String?

    public init(
        title: LocalizedStringKey,
        placeholder: LocalizedStringKey,
        read: @escaping (KeychainCredentialStore) -> KeychainReadResult,
        write: @escaping (KeychainCredentialStore, String) -> Bool,
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
            SecureField(placeholder, text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .onAppear(perform: load)

            HStack {
                Button("Save", action: save).keyboardShortcut(.defaultAction)
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
                    Text(readError).foregroundStyle(.red).font(.callout)
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red).font(.callout)
                }
                Spacer()
            }
            .animation(.smooth, value: savedFlash)
        } header: {
            Text(title)
        } footer: {
            footer()
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
            read: { $0.anthropicAPIKey() },
            write: { $0.saveAnthropicAPIKey($1) }
        ) {
            Link(
                "Get an API key from the Claude Console",
                destination: URL(string: "https://console.anthropic.com/settings/keys")!
            )
            .font(.callout)
        }
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
            read: { $0.openAIAPIKey() },
            write: { $0.saveOpenAIAPIKey($1) }
        ) {
            Link(
                "Get an API key from the OpenAI platform",
                destination: URL(string: "https://platform.openai.com/api-keys")!
            )
            .font(.callout)
        }
    }
}

#Preview("Anthropic key") {
    Form { AnthropicAPIKeySection() }
        .formStyle(.grouped)
        .environment(CollaborationCredentials(initialBackend: .anthropicAPI))
        .frame(width: 480, height: 260)
}
