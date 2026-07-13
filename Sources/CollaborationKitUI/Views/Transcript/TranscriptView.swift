import SwiftUI
import CollaborationKit

/// The scrolling transcript for a ``ConversationStore``.
///
/// Renders every ``ConversationItem`` via ``ConversationRowView``. Auto-scrolls
/// to the bottom as new items arrive, as the last item's content streams, and
/// while a turn is generating. Shows an "empty" state before the first turn
/// and a "Working…" row during generation.
public struct TranscriptView: View {
    /// The store whose ``ConversationStore/items`` are rendered.
    public var store: ConversationStore

    /// Optional per-tool icon lookup forwarded to ``ConversationRowView``.
    public let iconForTool: (String) -> String

    public init(
        store: ConversationStore,
        iconForTool: @escaping (String) -> String = ConversationRowView.defaultIcon(for:)
    ) {
        self.store = store
        self.iconForTool = iconForTool
    }

    private static let bottomID = "collaborationkit.transcript.bottom"

    public var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(store.items) { item in
                    ConversationRowView(item: item, iconForTool: iconForTool)
                        .id(item.id)
                        .listRowSeparator(.hidden)
                }
                if store.isGenerating {
                    thinkingRow
                        .listRowSeparator(.hidden)
                }
                // Stable sentinel at the bottom; always the scroll target so
                // streaming content (which changes row ids/heights) still
                // pins to the end.
                HStack {
                    Spacer()
                    Image(systemName: "sparkle").foregroundStyle(.secondary)
                    Spacer()
                }
                .id(Self.bottomID)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .overlay { emptyState }
            .onChange(of: store.items.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store.isGenerating) { _, _ in scrollToEnd(proxy) }
            .onChange(of: lastItemContentLength) { _, _ in scrollToEnd(proxy) }
        }
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

    @ViewBuilder
    private var emptyState: some View {
        if store.isEmpty, !store.isGenerating {
            ContentUnavailableView {
                Label("Start the Conversation", systemImage: "sparkles")
            } description: {
                Text("Type a message below. The assistant can read, write, and edit files through tools.")
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }
}
