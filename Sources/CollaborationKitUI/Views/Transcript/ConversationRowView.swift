import SwiftUI
import CollaborationKit

#if canImport(AppKit)
import AppKit
#endif

/// One transcript row, styled per ``ConversationItem/Kind``.
///
/// User prompts render as right-aligned accent bubbles, assistant prose as
/// left-aligned secondary bubbles, tool activity as compact rows with an icon
/// and argument summary, and harness errors as red-tinted bubbles.
public struct ConversationRowView: View {
    public let item: ConversationItem

    /// Optional per-tool icon lookup (SF Symbol name).
    ///
    /// Defaults to icons for the built-in `read`/`write`/`edit` file tools.
    /// Hosts can pass a closure to override.
    public let iconForTool: (String) -> String

    public init(
        item: ConversationItem,
        iconForTool: @escaping (String) -> String = ConversationRowView.defaultIcon(for:)
    ) {
        self.item = item
        self.iconForTool = iconForTool
    }

    public var body: some View {
        content.textSelection(.enabled)
    }

    // MARK: - Content dispatch

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .user(let text, let images):
            userBubble(text: text, images: images)

        case .assistant(let text):
            assistantBubble(text: text)

        case .tool(let name, let summary, let result, let isError):
            toolRow(name: name, summary: summary, result: result, isError: isError)

        case .error(let message):
            errorBubble(message: message)
        }
    }

    // MARK: - Bubbles

    private func userBubble(text: String, images: [ImageContent]) -> some View {
        bubble(alignment: .trailing, background: Color.accentColor.opacity(0.18)) {
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    AttachmentThumbnailsView(images: images)
                }
                if !text.isEmpty {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func assistantBubble(text: String) -> some View {
        bubble(alignment: .leading, background: Color.secondary.opacity(0.10)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text.isEmpty ? "…" : text)
                    .fixedSize(horizontal: false, vertical: true)
                durationLabel
            }
        }
    }

    private func errorBubble(message: String) -> some View {
        bubble(alignment: .leading, background: Color.red.opacity(0.12)) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolRow(name: String, summary: String, result: String?, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: iconForTool(name))
                    .foregroundStyle(isError ? .red : .secondary)
                Text(summary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if result == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    durationLabel
                }
            }
            if let result, resultWorthShowing(name: name, result: result, isError: isError) {
                Text(result)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(isError ? .red : .secondary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.red : Color.blue).opacity(0.08), in: .rect(cornerRadius: 8))
    }

    // MARK: - Duration

    /// The round-trip wait before this item appeared, e.g. "1.2s" — the time
    /// the user actually waited for the model/network, not the block-render
    /// time. Empty when unknown (first item of a turn, or still in flight).
    @ViewBuilder
    private var durationLabel: some View {
        if let latency = item.latency {
            Text(Self.durationText(latency))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        return String(format: "%.1fs", seconds)
    }

    // MARK: - Layout helpers

    private func bubble<Content: View>(
        alignment: HorizontalAlignment,
        background: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            content()
                .padding(10)
                .background(background, in: .rect(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
            if alignment == .leading { Spacer(minLength: 24) }
        }
    }

    /// Only show a tool result when it carries useful detail. For unknown
    /// tools, show it when the tool errored or when it looks like a read.
    private func resultWorthShowing(name: String, result: String, isError: Bool) -> Bool {
        if isError { return true }
        switch name {
        case "read": return true
        default: return false
        }
    }

    /// Default SF Symbol for a tool name. Covers the built-in `read`/
    /// `write`/`edit` file tools; unknown tools get a generic wrench.
    public nonisolated static func defaultIcon(for name: String) -> String {
        switch name {
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "edit": return "pencil"
        default: return "wrench.and.screwdriver"
        }
    }
}
