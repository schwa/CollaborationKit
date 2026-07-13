import CollaborationKit
import SwiftUI

/// Top-level chat view: transcript above the composer. Shows a "Sign in"
/// placeholder when the environment's ``CollaborationCredentials`` reports no
/// stored credentials for the current backend.
///
/// ```swift
/// CollaborationChatView(store: store)
///     .environment(credentials)
///     .collaborationComposerBorderStyle(.glow)
///     .collaborationComposerHeader { … }
///     .collaborationEmptyPlaceholder { … }
///     .collaborationMissingCredentialsPlaceholder { … }
///     .collaborationShowsDebugExportButton()
/// ```
///
/// The composer's border style, header caption, empty-transcript
/// placeholder, missing-credentials placeholder, and the built-in
/// debug-export ladybug button are all supplied via environment modifiers
/// on ``SwiftUICore/View`` (see the `collaboration…` family), so this view
/// takes a minimal initializer surface. Wire the debug export target with
/// ``SwiftUICore/View/collaborationDebugExport(store:model:defaultFilename:userInfo:)``.
public struct CollaborationChatView: View {
    public var store: ConversationStore

    /// Optional per-tool icon override, forwarded to the transcript.
    public let iconForTool: (String) -> String

    /// Whether the composer exposes the paperclip/image importer.
    public let allowsImageAttachments: Bool

    /// Called whenever the underlying store's ``ConversationStore/isGenerating``
    /// flag flips. Hosts can use this to disable other UI, pause compilation,
    /// or drive external indicators while a turn is in flight.
    public let onGeneratingChange: (Bool) -> Void

    @Environment(CollaborationCredentials.self)
    private var credentials
    @Environment(\.collaborationMissingCredentialsPlaceholder)
    private var missingCredentialsPlaceholder

    /// Shared attachment buffer plumbed into the composer and used as the
    /// sink for transcript image drops, so drags from Finder onto the
    /// transcript surface immediately in the composer's attachment strip.
    @State private var attachmentBuffer = ComposerAttachmentBuffer()

    public init(
        store: ConversationStore,
        iconForTool: @escaping (String) -> String = ConversationRowView.defaultIcon(for:),
        allowsImageAttachments: Bool = true,
        onGeneratingChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.store = store
        self.iconForTool = iconForTool
        self.allowsImageAttachments = allowsImageAttachments
        self.onGeneratingChange = onGeneratingChange
    }

    public var body: some View {
        VStack(spacing: 0) {
            if credentials.hasCredentials {
                TranscriptView(
                    store: store,
                    iconForTool: iconForTool,
                    onDropURLs: dropHandler
                )
                Divider()
                ComposerView(
                    store: store,
                    allowsImageAttachments: allowsImageAttachments
                )
            } else {
                missingCredentials
            }
        }
        .environment(\.composerAttachmentBuffer, allowsImageAttachments ? attachmentBuffer : nil)
        .onChange(of: store.isGenerating) { _, isGenerating in
            onGeneratingChange(isGenerating)
        }
    }

    private var dropHandler: (([URL]) -> Bool)? {
        guard allowsImageAttachments else { return nil }
        return { urls in
            attachmentBuffer.add(urls: urls)
            return true
        }
    }

    @ViewBuilder private var missingCredentials: some View {
        if let missingCredentialsPlaceholder {
            missingCredentialsPlaceholder.content()
        } else {
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
