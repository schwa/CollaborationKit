import SwiftUI
import CollaborationKit

/// The message composer: a prompt field, an optional attachment strip, and
/// send / attach / stop buttons.
///
/// Sends and stops through the supplied ``ConversationStore``. Enter sends;
/// Shift+Enter inserts a newline. Attachments are optional and gated by the
/// `allowsImageAttachments` flag; disable them for backends without image
/// support (most OpenAI-compatible local servers).
public struct ComposerView: View {
    public var store: ConversationStore

    /// Placeholder shown in the empty prompt field.
    public let placeholder: LocalizedStringKey

    /// Whether the paperclip / image importer is exposed. Set `false` for
    /// backends where images aren't supported.
    public let allowsImageAttachments: Bool

    @State private var prompt: String = ""
    @State private var attachments: [Attachment] = []
    @State private var showImporter: Bool = false
    @FocusState private var promptFocused: Bool

    public init(
        store: ConversationStore,
        placeholder: LocalizedStringKey = "Message…",
        allowsImageAttachments: Bool = true
    ) {
        self.store = store
        self.placeholder = placeholder
        self.allowsImageAttachments = allowsImageAttachments
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            promptField
        }
        .padding(12)
        .background(.background.secondary)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                addAttachments(from: urls)
            }
        }
        .onAppear { promptFocused = true }
    }

    // MARK: - Field

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ComposerAttachmentsView(attachments: attachments) { id in
                    attachments.removeAll { $0.id == id }
                }
            }

            TextField(placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(5...10)
                .foregroundStyle(.primary)
                .disabled(store.isGenerating)
                .focused($promptFocused)
                .onKeyPress(keys: [.return]) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        prompt += "\n"
                        return .handled
                    }
                    submit()
                    return .handled
                }

            actionsRow
        }
        .padding(12)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(promptFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
        }
    }

    private var actionsRow: some View {
        HStack {
            if store.usage.totalTokens > 0 {
                Label("\(store.usage.totalTokens) tokens", systemImage: "number")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
            }

            if allowsImageAttachments {
                Button("Attach Image", systemImage: "paperclip") {
                    showImporter = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(store.isGenerating)
                .help("Attach one or more images to the next message.")
            }

            Spacer()

            if store.isGenerating {
                Button("Stop", systemImage: "stop.fill") {
                    store.stop()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .clipShape(.circle)
                .help("Stop the current turn.")
            } else {
                Button("Send", systemImage: "arrow.up") {
                    submit()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .clipShape(.circle)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        let hasText = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !store.isGenerating
    }

    private func submit() {
        guard canSubmit else { return }
        let submitted = prompt
        let images = attachments.map(\.content)
        prompt = ""
        attachments = []
        store.send(submitted, images: images)
    }

    private func addAttachments(from urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let attachment = Attachment(url: url) else { continue }
            attachments.append(attachment)
        }
    }
}
