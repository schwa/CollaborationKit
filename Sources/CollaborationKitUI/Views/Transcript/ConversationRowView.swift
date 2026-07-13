import SwiftUI
import CollaborationKit

#if canImport(AppKit)
import AppKit
#endif

/// One transcript row, styled per ``ConversationItem/Kind``.
///
/// Each row is a distinct card with a role header (icon + label + latency)
/// and content underneath, so a scrolling transcript reads as a series of
/// clearly separated blocks rather than a wall of bubbles.
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
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(accessibilityValueText)
    }

    // MARK: - Accessibility labels

    /// Screen reader label describing the row's role + timing at a glance.
    private var accessibilityLabelText: String {
        switch item.kind {
        case .user:
            return "User message"

        case .assistant:
            return "Assistant reply"

        case .tool(let name, _, _, let isError):
            return isError ? "Tool \(name), errored" : "Tool \(name)"

        case .error:
            return "Error"
        }
    }

    /// Screen reader value with the row's content plus latency when known.
    private var accessibilityValueText: String {
        var parts: [String] = []
        switch item.kind {
        case .user(let text, let images):
            parts.append(text)
            if !images.isEmpty { parts.append("\(images.count) attached image\(images.count == 1 ? "" : "s")") }

        case .assistant(let text):
            parts.append(text.isEmpty ? "still generating" : text)

        case .tool(_, let summary, let result, _):
            parts.append(summary)
            if let result { parts.append("Result: \(result)") } else { parts.append("pending") }

        case .error(let message):
            parts.append(message)
        }
        if let latency = item.latency {
            parts.append("Waited \(Self.durationText(latency))")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIcon)
                .foregroundStyle(accent)
                .font(.caption)
                .frame(width: 14)
            Text(headerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .textCase(.uppercase)
                .tracking(0.4)
            Spacer(minLength: 4)
            durationLabel
        }
    }

    private var headerIcon: String {
        switch item.kind {
        case .user: return "person.crop.circle"
        case .assistant: return "sparkles"
        case .tool(let name, _, _, let isError):
            return isError ? "exclamationmark.triangle" : iconForTool(name)
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var headerLabel: String {
        switch item.kind {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .tool(let name, _, _, _): return "Tool · \(name)"
        case .error: return "Error"
        }
    }

    private var accent: Color {
        switch item.kind {
        case .user: return .accentColor
        case .assistant: return .indigo
        case .tool(_, _, _, let isError): return isError ? .red : .blue
        case .error: return .red
        }
    }

    private var background: Color {
        switch item.kind {
        case .user: return Color.accentColor.opacity(0.06)
        case .assistant: return Color.indigo.opacity(0.05)
        case .tool(_, _, _, let isError): return (isError ? Color.red : Color.blue).opacity(0.05)
        case .error: return Color.red.opacity(0.08)
        }
    }

    private var borderColor: Color {
        accent.opacity(0.25)
    }

    // MARK: - Content dispatch

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .user(let text, let images):
            userContent(text: text, images: images)

        case .assistant(let text):
            assistantContent(text: text)

        case .tool(let name, let summary, let result, let isError):
            toolContent(name: name, summary: summary, result: result, isError: isError)

        case .error(let message):
            errorContent(message: message)
        }
    }

    // MARK: - Content

    private func userContent(text: String, images: [ImageContent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                AttachmentThumbnailsView(images: images)
            }
            if !text.isEmpty {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func assistantContent(text: String) -> some View {
        Text(text.isEmpty ? "…" : text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toolContent(name: String, summary: String, result: String?, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if result == nil {
                    ProgressView().controlSize(.mini)
                }
            }
            if let result, resultWorthShowing(name: name, result: result, isError: isError) {
                Text(result)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isError ? .red : .secondary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
            }
        }
    }

    private func errorContent(message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Duration

    /// The round-trip wait before this item appeared, e.g. "1.2s".
    @ViewBuilder
    private var durationLabel: some View {
        if let latency = item.latency {
            Text(Self.durationText(latency))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        return String(format: "%.1fs", seconds)
    }

    /// Only show a tool result when it carries useful detail. For unknown
    /// tools, show when the tool errored or looks like a read.
    private func resultWorthShowing(name: String, result: String, isError: Bool) -> Bool {
        if isError { return true }
        switch name {
        case "read": return true
        default: return false
        }
    }

    /// Default SF Symbol for a tool name. Covers the built-in
    /// `read`/`write`/`edit` file tools; unknown tools get a generic wrench.
    public nonisolated static func defaultIcon(for name: String) -> String {
        switch name {
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "edit": return "pencil"
        default: return "wrench.and.screwdriver"
        }
    }
}

#Preview("Row samples") {
    let user = ConversationItem(
        id: .message(UUID()), kind: .user("Add a note titled Groceries with body eggs, milk.", images: []),
        timestamp: .now, duration: nil, latency: nil
    )
    let assistant = ConversationItem(
        id: .message(UUID()), kind: .assistant("Sure — I'll create it now."),
        timestamp: .now, duration: 0.4, latency: 0.9
    )
    let tool = ConversationItem(
        id: .tool("t1"), kind: .tool(name: "create", summary: "creating a note", result: nil, isError: false),
        timestamp: .now, duration: nil, latency: nil
    )
    let error = ConversationItem(
        id: .error(1), kind: .error("Rate limited (429)."),
        timestamp: .now, duration: nil, latency: nil
    )
    return ScrollView {
        VStack(spacing: 10) {
            ConversationRowView(item: user)
            ConversationRowView(item: assistant)
            ConversationRowView(item: tool)
            ConversationRowView(item: error)
        }
        .padding()
    }
    .frame(width: 520, height: 480)
}
