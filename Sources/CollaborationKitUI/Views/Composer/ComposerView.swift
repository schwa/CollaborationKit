import CollaborationKit
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

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

    @State private var prompt: String = ""
    @State private var ownedBuffer = ComposerAttachmentBuffer()
    @State private var showImporter: Bool = false
    @FocusState private var promptFocused: Bool

    /// Shell-style recall history. Scope is this composer instance's
    /// lifetime — not persisted across launches.
    @State private var history = PromptHistory()
    @Environment(\.composerAttachmentBuffer) private var injectedBuffer
    @Environment(\.exportDebugLogAction) private var exportDebugLogAction
    @Environment(\.collaborationComposerHeader) private var header
    @Environment(\.collaborationComposerBorderStyle) private var borderStyle
    @Environment(\.collaborationShowsDebugExportButton) private var showsDebugExportButton

    private var buffer: ComposerAttachmentBuffer {
        injectedBuffer ?? ownedBuffer
    }

    private var attachments: [Attachment] { buffer.attachments }

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
            if let header {
                header.content()
            }
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
        .modifier(ComposerPasteModifier(enabled: allowsImageAttachments, buffer: buffer))
        .onAppear { promptFocused = true }
    }

    // MARK: - Field

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ComposerAttachmentsView(attachments: attachments) { id in
                    buffer.remove(id: id)
                }
            }

            TextField(placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(5...10)
                .foregroundStyle(.primary)
                .focused($promptFocused)
                .onKeyPress(keys: [.return]) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        prompt += "\n"
                        return .handled
                    }
                    submit()
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { keyPress in
                    // A multi-line prompt uses up/down for caret
                    // movement inside the field; only intercept when the
                    // draft is a single line, so recall never fights
                    // editing intent.
                    guard !prompt.contains("\n") else { return .ignored }
                    let recalled: String?
                    switch keyPress.key {
                    case .upArrow:
                        recalled = history.recallPrevious(current: prompt)
                    case .downArrow:
                        recalled = history.recallNext(current: prompt)
                    default:
                        return .ignored
                    }
                    guard let recalled else { return .ignored }
                    prompt = recalled
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

            if let progress = store.compactionProgress {
                Label(
                    "\(formatCompactionCount(progress.current)) / \(formatCompactionCount(progress.limit))",
                    systemImage: "arrow.down.right.and.arrow.up.left"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(
                    "\(progress.current) of \(progress.limit) input tokens used before compaction"
                )
            }

            if allowsImageAttachments {
                Button("Attach Image", systemImage: "paperclip") {
                    showImporter = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel("Attach image")
                .accessibilityHint("Add images to your next message.")
            }

            if showsDebugExportButton, let exportDebugLogAction {
                Button("Export Debug Log", systemImage: "ladybug") {
                    exportDebugLogAction()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel("Export debug log")
                .accessibilityHint("Save a JSON snapshot of the current conversation for bug reports.")
            }

            if store.pendingPromptCount > 0 {
                Label("\(store.pendingPromptCount) queued", systemImage: "list.bullet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(store.pendingPromptCount) queued prompt\(store.pendingPromptCount == 1 ? "" : "s")")
            }

            Spacer()

            if store.isGenerating {
                StopButton { store.stop() }
                    .accessibilityLabel("Stop")
                    .accessibilityHint("Cancel the current turn.")
            }

            // While generating, only show the queue arrow when there's
            // something to queue; otherwise the stop button stands alone.
            if !store.isGenerating || canSubmit {
                sendButton
            }
        }
    }

    @ViewBuilder private var sendButton: some View {
        Button(store.isGenerating ? "Queue" : "Send", systemImage: "arrow.up") {
            submit()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .clipShape(.circle)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .accessibilityLabel(store.isGenerating ? "Queue message" : "Send message")
        .accessibilityHint(
            canSubmit
                ? (store.isGenerating ? "Queue this message to send after the current turn finishes." : "Send your message.")
                : "Type a message first."
        )
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        let hasText = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !attachments.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let submitted = prompt
        let images = attachments.map(\.content)
        prompt = ""
        buffer.clear()
        history.record(submitted)
        store.send(submitted, images: images)
    }

    private func addAttachments(from urls: [URL]) {
        buffer.add(urls: urls)
    }

    /// Compact humanized formatter for the compaction chip: "12.3k",
    /// "1.2M", or the raw integer under 1000.
    private func formatCompactionCount(_ value: Int) -> String {
        let n = Double(value)
        if abs(n) >= 1_000_000 {
            return String(format: "%.1fM", n / 1_000_000)
        }
        if abs(n) >= 1_000 {
            return String(format: "%.1fk", n / 1_000)
        }
        return "\(value)"
    }
}

/// Handles ⌘V into the composer by extracting image data or file URLs from
/// the pasteboard and appending them to the composer's attachment buffer.
/// macOS-only for now; iOS paste requires a different code path (see
/// `pasteDestination`) and is deferred.
private struct ComposerPasteModifier: ViewModifier {
    var enabled: Bool
    var buffer: ComposerAttachmentBuffer

    func body(content: Content) -> some View {
        #if canImport(AppKit)
        if enabled {
            content
                // File URL pastes (Finder copy) — pasteDestination competes
                // with the focused TextField at a higher level than
                // onPasteCommand, so URL pastes route here instead of being
                // pasted as text into the field.
                .pasteDestination(for: URL.self) { urls in
                    buffer.add(urls: urls)
                }
                // Raw image data (screenshots, cross-app image copies).
                // No competing text representation, so onPasteCommand at
                // container scope is enough.
                .onPasteCommand(of: [.image]) { providers in
                    Task { @MainActor in
                        await handleImages(providers: providers)
                    }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if canImport(AppKit)
    private func handleImages(providers: [NSItemProvider]) async {
        for provider in providers {
            if let attachment = await Self.loadImageAttachment(from: provider) {
                buffer.attachments.append(attachment)
            }
        }
    }

    private static func loadImageAttachment(from provider: NSItemProvider) async -> Attachment? {
        // Try common image UTIs in preference order. TIFF is what the
        // system pasteboard offers for cross-app screenshots on macOS.
        for typeIdentifier in [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.image.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { continue }
            if let data = await loadData(from: provider, typeIdentifier: typeIdentifier),
               let attachment = Attachment(pastedData: data, typeIdentifier: typeIdentifier) {
                return attachment
            }
        }
        return nil
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
    #endif
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

private actor _PreviewNullProvider: ModelProvider {
    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private func _previewStore() -> ConversationStore {
    ConversationStore(session: LLMSession(provider: _PreviewNullProvider()))
}

#Preview("Plain") {
    ComposerView(store: _previewStore()).frame(width: 520)
}
#Preview("Glow") {
    ComposerView(store: _previewStore())
        .collaborationComposerBorderStyle(.glow)
        .frame(width: 520)
}
#Preview("With Header") {
    ComposerView(store: _previewStore())
        .collaborationComposerHeader {
            Label("cpu · OpenAI · gpt-4o", systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 520)
}
