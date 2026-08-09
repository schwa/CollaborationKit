import CollaborationKit
import SwiftUI

/// A prompt waiting behind the in-flight turn, rendered at the end of the
/// transcript.
///
/// Deliberately quieter than a sent ``ConversationRowView``: dashed border,
/// no fill, "Queued" header. The cancel button drops just this prompt (see
/// ``ConversationStore/cancelPendingPrompt(_:)``) — the running turn and the
/// rest of the queue are untouched.
struct QueuedPromptRowView: View {
    let prompt: ConversationStore.QueuedPrompt
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !prompt.text.isEmpty {
                Text(prompt.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !prompt.images.isEmpty {
                AttachmentThumbnailsView(images: prompt.images)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queued message")
        .accessibilityValue(prompt.text)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .accessibilityHidden(true)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 14)
            Text("Queued")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Spacer(minLength: 4)
            Button("Cancel", systemImage: "xmark.circle.fill", action: onCancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancel queued message")
                .accessibilityHint("Removes this prompt before it is sent.")
        }
    }
}

#Preview("Queued") {
    QueuedPromptRowView(
        prompt: ConversationStore.QueuedPrompt(
            id: UUID(),
            text: "And then summarise the diff.",
            images: []
        )
    ) {}
    .padding()
    .frame(width: 420)
}
