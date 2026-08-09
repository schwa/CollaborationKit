import CollaborationKit
import SwiftUI

/// The scrolling transcript for a ``ConversationStore``.
///
/// Renders every ``ConversationItem`` via ``ConversationRowView``. Auto-scrolls
/// to the bottom as new items arrive, as the last item's content streams, and
/// while a turn is generating. Shows an "empty" state before the first turn,
/// a "Working…" row during generation, and a pending row per queued prompt
/// (each cancellable on its own).
public struct TranscriptView: View {
    /// The store whose ``ConversationStore/items`` are rendered.
    public var store: ConversationStore

    /// Optional per-tool icon lookup forwarded to ``ConversationRowView``.
    public let iconForTool: (String) -> String

    /// Optional handler invoked when file URLs are dropped onto the
    /// transcript. When `nil`, the transcript accepts no drops. Hosts using
    /// ``CollaborationChatView`` get this wired up automatically to route
    /// image drops into the composer.
    public let onDropURLs: (([URL]) -> Bool)?

    @Environment(\.collaborationEmptyPlaceholder) private var emptyPlaceholder

    public init(
        store: ConversationStore,
        iconForTool: @escaping (String) -> String = ConversationRowView.defaultIcon(for:),
        onDropURLs: (([URL]) -> Bool)? = nil
    ) {
        self.store = store
        self.iconForTool = iconForTool
        self.onDropURLs = onDropURLs
    }

    private static let bottomID = "collaborationkit.transcript.bottom"

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.items) { item in
                        ConversationRowView(
                            item: item,
                            iconForTool: iconForTool,
                            canRollBack: store.canRollBack(to: item.id)
                        ) {
                            store.rollBack(through: item.id)
                        }
                        .id(item.id)
                    }
                    if store.isGenerating {
                        thinkingRow
                    }
                    ForEach(store.queuedPrompts) { queued in
                        QueuedPromptRowView(prompt: queued) {
                            store.cancelPendingPrompt(queued.id)
                        }
                    }
                    // Stable sentinel at the bottom; always the scroll target
                    // so streaming content (which changes row ids/heights)
                    // still pins to the end.
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(12)
            }
            .background(.background.secondary)
            .overlay { emptyState }
            .onChange(of: scrollSignal) { _, _ in scrollToEnd(proxy) }
            .modifier(TranscriptDropModifier(onDropURLs: onDropURLs))
        }
    }

    /// Compound signal for autoscroll: item count (new row appeared),
    /// generating flag (thinking row flips), and the last item's content
    /// length (streaming text grows without changing count).
    private var scrollSignal: ScrollSignal {
        ScrollSignal(
            itemCount: store.items.count,
            queuedCount: store.pendingPromptCount,
            isGenerating: store.isGenerating,
            lastContentLength: lastItemContentLength
        )
    }

    private struct ScrollSignal: Equatable {
        var itemCount: Int
        var queuedCount: Int
        var isGenerating: Bool
        var lastContentLength: Int
    }

    /// A signal that grows as the last item's content streams in, used to
    /// keep the view pinned to the bottom during a turn.
    private var lastItemContentLength: Int {
        guard let last = store.items.last else { return 0 }
        switch last.kind {
        case .user(let text, _):
            return text.count

        case .assistant(let text), .error(let text):
            return text.count

        case .tool(_, _, let result, _):
            return result?.count ?? 0
        }
    }

    @ViewBuilder private var emptyState: some View {
        if store.isEmpty, !store.isGenerating {
            if let emptyPlaceholder {
                emptyPlaceholder.content()
            } else {
                ContentUnavailableView {
                    Label("Start the Conversation", systemImage: "sparkles")
                } description: {
                    Text("Type a message below to get started.")
                }
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant is generating a reply")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }
}

/// Attaches a URL drop destination to the transcript scroll area only when a
/// handler is supplied. Absent a handler, no drop target is installed so the
/// view doesn't silently swallow drops the host wants to route elsewhere.
private struct TranscriptDropModifier: ViewModifier {
    var onDropURLs: (([URL]) -> Bool)?

    func body(content: Content) -> some View {
        if let onDropURLs {
            content.dropDestination(for: URL.self) { urls, _ in
                onDropURLs(urls)
            }
        } else {
            content
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

#Preview("Empty") {
    TranscriptView(store: _previewStore())
        .frame(width: 520, height: 400)
}
