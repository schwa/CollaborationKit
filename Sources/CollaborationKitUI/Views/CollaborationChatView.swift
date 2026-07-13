import CollaborationKit
import SwiftUI

/// Top-level chat view: transcript above the composer. Shows a "Sign in"
/// placeholder when the environment's ``CollaborationCredentials`` reports no
/// stored credentials for the current backend.
///
/// ```swift
/// CollaborationChatView(store: store)
///     .environment(credentials)
/// ```
public struct CollaborationChatView: View {
    public var store: ConversationStore

    /// Optional per-tool icon override, forwarded to the transcript.
    public let iconForTool: (String) -> String

    /// Whether the composer exposes the paperclip/image importer.
    public let allowsImageAttachments: Bool

    /// Composer border style (plain or glow).
    public let composerBorderStyle: ComposerBorderStyle

    /// Called whenever the underlying store's ``ConversationStore/isGenerating``
    /// flag flips. Hosts can use this to disable other UI, pause compilation,
    /// or drive external indicators while a turn is in flight.
    public let onGeneratingChange: (Bool) -> Void

    /// Host-provided empty-state view forwarded to ``TranscriptView``. When
    /// `nil`, the transcript uses its generic default placeholder. Hosts
    /// should override this to describe what their assistant actually does.
    public let emptyPlaceholder: (() -> AnyView)?

    @Environment(CollaborationCredentials.self)
    private var credentials

    public init(
        store: ConversationStore,
        iconForTool: @escaping (String) -> String = ConversationRowView.defaultIcon(for:),
        allowsImageAttachments: Bool = true,
        composerBorderStyle: ComposerBorderStyle = .plain,
        onGeneratingChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.store = store
        self.iconForTool = iconForTool
        self.allowsImageAttachments = allowsImageAttachments
        self.composerBorderStyle = composerBorderStyle
        self.onGeneratingChange = onGeneratingChange
        self.emptyPlaceholder = nil
    }

    /// Creates a chat view with a custom empty-state placeholder.
    public init<Placeholder: View>(
        store: ConversationStore,
        iconForTool: @escaping (String) -> String = ConversationRowView.defaultIcon(for:),
        allowsImageAttachments: Bool = true,
        composerBorderStyle: ComposerBorderStyle = .plain,
        onGeneratingChange: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder emptyPlaceholder: @escaping () -> Placeholder
    ) {
        self.store = store
        self.iconForTool = iconForTool
        self.allowsImageAttachments = allowsImageAttachments
        self.composerBorderStyle = composerBorderStyle
        self.onGeneratingChange = onGeneratingChange
        self.emptyPlaceholder = { AnyView(emptyPlaceholder()) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if credentials.hasCredentials {
                transcript
                Divider()
                ComposerView(
                    store: store,
                    allowsImageAttachments: allowsImageAttachments,
                    borderStyle: composerBorderStyle
                )
            } else {
                missingCredentials
            }
        }
        .onChange(of: store.isGenerating) { _, isGenerating in
            onGeneratingChange(isGenerating)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let emptyPlaceholder {
            TranscriptView(store: store, iconForTool: iconForTool) {
                emptyPlaceholder()
            }
        } else {
            TranscriptView(store: store, iconForTool: iconForTool)
        }
    }

    private var missingCredentials: some View {
        ContentUnavailableView {
            Label("Sign in to Continue", systemImage: "key.horizontal")
        } description: {
            Text("Add credentials for the selected provider in Settings.")
        } actions: {
            #if os(macOS)
            SettingsLink { Text("Open Settings…") }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

#Preview {
    CollaborationChatView(store: _previewStore())
        .environment(CollaborationCredentials())
        .frame(width: 640, height: 480)
}
