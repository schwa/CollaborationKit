import CollaborationKit
import SwiftUI

/// A `Section` for configuring a local OpenAI-compatible LLM server
/// (LM Studio, Ollama, llama.cpp, vLLM, etc.).
///
/// Shows a text field for the base URL, persists the override into
/// ``CollaborationCredentials`` (keyed by the current backend id), and
/// exposes a Reset control to revert to the backend's built-in default.
///
/// The URL is validated on save. Anything that isn't a well-formed URL with
/// an `http` or `https` scheme is rejected with an inline error.
public struct LocalServerSection: View {
    @Environment(CollaborationCredentials.self)
    private var credentials

    public let title: LocalizedStringKey
    public let placeholder: LocalizedStringKey

    @State private var text: String = ""
    @State private var savedFlash: Bool = false
    @State private var saveError: String?

    public init(
        title: LocalizedStringKey = "Local Server",
        placeholder: LocalizedStringKey = "http://localhost:1234"
    ) {
        self.title = title
        self.placeholder = placeholder
    }

    public var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                        .onSubmit(save)
                        .onAppear(perform: load)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Button("Reset", action: reset)
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } label: {
                Text("Base URL")
            }
            statusRow
        } header: {
            Text(title)
        } footer: {
            Text(footerText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusRow: some View {
        if savedFlash || saveError != nil {
            HStack {
                if savedFlash {
                    Text("Saved")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .transition(.opacity)
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red).font(.callout)
                }
                Spacer()
            }
            .animation(.smooth, value: savedFlash)
        }
    }

    private var footerText: LocalizedStringKey {
        "Enter the server URL (no `/v1` suffix). Reset restores the built-in default."
    }

    private func load() {
        text = credentials.baseURL()?.absoluteString ?? ""
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            credentials.setBaseURL(nil)
            saveError = nil
            flashSaved()
            return
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            saveError = "Enter an http:// or https:// URL."
            return
        }
        credentials.setBaseURL(url)
        saveError = nil
        text = url.absoluteString
        flashSaved()
    }

    private func reset() {
        credentials.setBaseURL(nil)
        text = ""
        saveError = nil
        flashSaved()
    }

    private func flashSaved() {
        savedFlash = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            savedFlash = false
        }
    }
}

#Preview("Local server — LM Studio") {
    Form { LocalServerSection() }
        .formStyle(.grouped)
        .environment(CollaborationCredentials(
            backends: [.lmStudio()],
            initialBackend: .lmStudio()
        ))
        .frame(width: 520, height: 260)
}
