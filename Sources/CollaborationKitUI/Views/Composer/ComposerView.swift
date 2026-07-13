import SwiftUI
import CollaborationKit

/// The message composer: a prompt field, an optional attachment strip, and
/// send / attach / stop buttons.
///
/// Sends and stops through the supplied ``ConversationStore``. Enter sends;
/// Shift+Enter inserts a newline. Attachments are optional and gated by the
/// `allowsImageAttachments` flag; disable them for backends without image
/// support (most OpenAI-compatible local servers).
/// The visual style of the composer's prompt field border.
public enum ComposerBorderStyle: Sendable {
    /// A plain 1pt border that turns accent-colored on focus. Default.
    case plain
    /// Xcode-Coding-Intelligence-style multicolor glow. See ``GlowingPromptBorder``.
    case glow
}

public struct ComposerView: View {
    public var store: ConversationStore

    /// Placeholder shown in the empty prompt field.
    public let placeholder: LocalizedStringKey

    /// Whether the paperclip / image importer is exposed. Set `false` for
    /// backends where images aren't supported.
    public let allowsImageAttachments: Bool

    /// How the prompt field is bordered. Defaults to ``ComposerBorderStyle/plain``.
    public let borderStyle: ComposerBorderStyle

    @State private var prompt: String = ""
    @State private var attachments: [Attachment] = []
    @State private var showImporter: Bool = false
    @FocusState private var promptFocused: Bool

    public init(
        store: ConversationStore,
        placeholder: LocalizedStringKey = "Message…",
        allowsImageAttachments: Bool = true,
        borderStyle: ComposerBorderStyle = .plain
    ) {
        self.store = store
        self.placeholder = placeholder
        self.allowsImageAttachments = allowsImageAttachments
        self.borderStyle = borderStyle
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
        .modifier(PromptFieldBackground(style: borderStyle, active: promptFocused))
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
                StopButton { store.stop() }
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

/// Applies either the plain or the glowing prompt border, so ``ComposerView``
/// doesn't have to fork the view tree at the call site.
private struct PromptFieldBackground: ViewModifier {
    var style: ComposerBorderStyle
    var active: Bool

    func body(content: Content) -> some View {
        switch style {
        case .plain:
            content
                .background(.background, in: .rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            active ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: 1
                        )
                }

        case .glow:
            content.glowingPromptBorder(cornerRadius: 12, active: active)
        }
    }
}
