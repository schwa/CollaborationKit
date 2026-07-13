import Foundation
import CollaborationKit

/// Pure projection from ``MessageMirror`` to renderable ``ConversationItem``s.
///
/// No state, no observation, no actor isolation — just a function of the
/// mirror. Used by ``ConversationStore`` after every mutation to keep the
/// items array in sync, and directly unit-testable without any SwiftUI or
/// Session dependencies.
public enum TranscriptProjection {
    /// Projects the mirror into rendered rows plus the set of `ItemID`s
    /// referenced by those rows (so callers can garbage-collect stale
    /// presentation entries via ``MessageMirror/compact(livingIDs:)``).
    public static func project(_ mirror: MessageMirror) -> (items: [ConversationItem], livingIDs: Set<ItemID>) {
        var rows: [ConversationItem] = []
        var livingIDs: Set<ItemID> = []

        for message in mirror.messages {
            switch message.role {
            case .user:
                if let (text, images) = userPrompt(message) {
                    let id = ItemID.message(message.id)
                    livingIDs.insert(id)
                    rows.append(makeRow(
                        id: id,
                        fallbackTimestamp: message.timestamp,
                        kind: .user(text, images: images),
                        presentation: mirror.presentation[id],
                        priorEnd: rows.last?.endTimestamp
                    ))
                }

            case .assistant:
                let previousEnd = rows.last?.endTimestamp
                appendAssistantRows(
                    message,
                    into: &rows,
                    livingIDs: &livingIDs,
                    presentation: mirror.presentation,
                    priorEnd: previousEnd
                )
            }
        }

        if let streaming = mirror.streamingAssistantText {
            let id = ItemID.streamingAssistant
            livingIDs.insert(id)
            rows.append(makeRow(
                id: id,
                fallbackTimestamp: Date(),
                kind: .assistant(streaming),
                presentation: mirror.presentation[id],
                priorEnd: rows.last?.endTimestamp
            ))
        }

        for overlay in mirror.errorOverlays {
            let id = ItemID.error(overlay.seq)
            livingIDs.insert(id)
            rows.append(makeRow(
                id: id,
                fallbackTimestamp: Date(),
                kind: .error(overlay.message),
                presentation: mirror.presentation[id],
                priorEnd: rows.last?.endTimestamp
            ))
        }

        return (rows, livingIDs)
    }

    // MARK: - Helpers

    /// Extracts a user prompt (text + images) from a user message, or `nil`
    /// when the message only carries tool results.
    private static func userPrompt(_ message: Message) -> (String, [ImageContent])? {
        var text = ""
        var images: [ImageContent] = []
        var sawPromptContent = false
        for block in message.content {
            switch block {
            case .text(let value):
                text = value
                sawPromptContent = true

            case .image(let image):
                images.append(image)
                sawPromptContent = true

            case .toolCall:
                break
            }
        }
        return sawPromptContent ? (text, images) : nil
    }

    /// Projects an assistant message into one prose row (if it has text) plus
    /// one row per tool call. Each ``ToolCall`` owns its result, so the tool
    /// row updates in place — no separate result message.
    private static func appendAssistantRows(
        _ message: Message,
        into rows: inout [ConversationItem],
        livingIDs: inout Set<ItemID>,
        presentation: [ItemID: MessageMirror.Presentation],
        priorEnd: Date?
    ) {
        var previousEnd = priorEnd
        var prose = ""
        for block in message.content {
            if case .text(let value) = block { prose += value }
        }
        if !prose.isEmpty {
            let id = ItemID.message(message.id)
            livingIDs.insert(id)
            let row = makeRow(
                id: id,
                fallbackTimestamp: message.timestamp,
                kind: .assistant(prose),
                presentation: presentation[id],
                priorEnd: previousEnd
            )
            rows.append(row)
            previousEnd = row.endTimestamp
        }
        for block in message.content {
            guard case .toolCall(let call) = block else { continue }
            let id = ItemID.tool(call.use.id)
            livingIDs.insert(id)
            let summary = presentation[id]?.summary ?? call.use.name
            let row = makeRow(
                id: id,
                fallbackTimestamp: message.timestamp,
                kind: .tool(
                    name: call.use.name,
                    summary: summary,
                    result: call.result?.content,
                    isError: call.result?.isError ?? false
                ),
                presentation: presentation[id],
                priorEnd: previousEnd
            )
            rows.append(row)
            previousEnd = row.endTimestamp
        }
    }

    /// Builds one projected row. Latency is computed from `priorEnd` (the
    /// end of the previous row) — the wall-clock gap the user waited between
    /// rows appearing.
    private static func makeRow(
        id: ItemID,
        fallbackTimestamp: Date,
        kind: ConversationItem.Kind,
        presentation: MessageMirror.Presentation?,
        priorEnd: Date?
    ) -> ConversationItem {
        let timestamp = presentation?.timestamp ?? fallbackTimestamp
        let latency = priorEnd.map { timestamp.timeIntervalSince($0) }.flatMap { $0 >= 0 ? $0 : nil }
        return ConversationItem(
            id: id,
            kind: kind,
            timestamp: timestamp,
            duration: presentation?.duration,
            latency: latency
        )
    }
}

private extension ConversationItem {
    /// The row's end wall-clock timestamp (start + duration, if known).
    var endTimestamp: Date { timestamp.addingTimeInterval(duration ?? 0) }
}
