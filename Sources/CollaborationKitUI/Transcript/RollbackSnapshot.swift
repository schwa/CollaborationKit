import Foundation

/// State captured at the moment a user prompt is sent so the transcript can
/// later be rolled back to just before that prompt.
///
/// The transcript itself is a projection of the model's ``Message`` history,
/// so ``ConversationStore/rollBack(through:)`` only has to truncate the two
/// histories (mirror + session) — the rows fall away on the next reproject.
/// What CollaborationKit *can't* undo on its own is host-side state (an
/// editor's document text, an image the user was working on, the current
/// map region…). That's what this snapshot carries.
///
/// The payload is a closure so the API is generic in the host's context
/// without making ``ConversationStore`` itself generic. Hosts capture
/// whatever they need at send time and reapply it on rollback:
///
/// ```swift
/// let snapshotSource = editor.text
/// store.send(prompt, snapshot: RollbackSnapshot { [editor] in
///     editor.replaceText(with: snapshotSource, actionName: "Roll Back")
/// })
/// ```
///
/// The apply closure runs on the main actor from
/// ``ConversationStore/rollBack(through:)``.
public struct RollbackSnapshot: Sendable {
    /// Restores host state to what it was when the snapshot was captured.
    let apply: @MainActor @Sendable () -> Void

    /// Creates a snapshot with a restore closure.
    ///
    /// The closure must capture (copy) whatever host state is needed to
    /// reapply on rollback. It runs on the main actor.
    public init(apply: @escaping @MainActor @Sendable () -> Void) {
        self.apply = apply
    }

    /// A snapshot whose apply closure does nothing.
    ///
    /// Use when the transcript should be rewindable but there's no host
    /// state to restore (e.g. a stateless chat with no side effects).
    public static let empty = RollbackSnapshot(apply: {})
}
