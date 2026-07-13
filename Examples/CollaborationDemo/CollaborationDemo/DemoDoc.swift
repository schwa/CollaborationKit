import CollaborationKit
import Foundation
import Observation

/// A recently-applied assistant edit. Rendered as a highlight in the
/// editor. Persists until the user edits the document (which invalidates
/// character offsets) — new assistant edits within the same turn stack on
/// top so the user can see the whole batch at once.
struct DocHighlight: Identifiable, Sendable, Equatable {
    let id: UUID
    /// Character offset (in `DemoDoc.text`) of the edit's start.
    var offset: Int
    /// Character length of the edit. Zero-length deletes get widened
    /// to 1 char so the user can still see the marker.
    var length: Int
}

@MainActor
@Observable
@CollaborationTools
final class DemoDoc {
    /// Full document text. Source of truth; the editor mirrors it.
    var text: String = defaultText

    /// The most-recent assistant edit still highlighted. Each new
    /// assistant edit (or user edit) supersedes it, so only the latest
    /// change is visible.
    var highlights: [DocHighlight] = []

    /// Character offset the editor should scroll to on the next
    /// layout pass. Cleared by the view once consumed. Set by tool
    /// edits so the assistant's first mutation of a batch is visible.
    var pendingScrollOffset: Int?

    private static let defaultText = """
    # Draft

    Start typing here, or ask the assistant to help.

    The assistant can insert, replace, or delete ranges of this document. \
    Its edits are highlighted briefly so you can see what changed.
    """

    /// Return the full document text.
    @CollaborationTool
    func getText() -> String {
        text
    }

    /// Return the total character count of the document.
    @CollaborationTool
    func length() -> Int {
        text.count
    }

    /// Insert `text` at the given character offset. Offset 0 is the
    /// start of the document; `length()` is the end.
    @CollaborationTool
    func insert(offset: Int, text: String) throws -> String {
        let idx = try index(at: offset)
        var next = self.text
        next.insert(contentsOf: text, at: idx)
        apply(newText: next, editOffset: offset, editLength: text.count)
        return "Inserted \(text.count) character(s) at \(offset)."
    }

    /// Replace the half-open character range `[start, end)` with `text`.
    @CollaborationTool
    func replace(start: Int, end: Int, text: String) throws -> String {
        let range = try range(start: start, end: end)
        var next = self.text
        next.replaceSubrange(range, with: text)
        apply(newText: next, editOffset: start, editLength: text.count)
        return "Replaced \(end - start) character(s) with \(text.count)."
    }

    /// Delete the half-open character range `[start, end)`.
    @CollaborationTool
    func delete(start: Int, end: Int) throws -> String {
        let range = try range(start: start, end: end)
        var next = self.text
        next.removeSubrange(range)
        // A pure deletion has zero length; use a 1-char marker so the
        // user sees where it landed.
        apply(newText: next, editOffset: start, editLength: 0)
        return "Deleted \(end - start) character(s)."
    }

    /// Append `text` at the end of the document.
    @CollaborationTool
    func append(text: String) -> String {
        let offset = self.text.count
        self.text.append(text)
        apply(newText: self.text, editOffset: offset, editLength: text.count)
        return "Appended \(text.count) character(s)."
    }

    /// Replace the entire document with `text`.
    @CollaborationTool(requiresApproval: true)
    func rewrite(text: String) -> String {
        let count = text.count
        self.text = text
        // Rewrite invalidates prior offsets. Drop existing highlights
        // and mark the whole doc as changed.
        highlights = [DocHighlight(id: UUID(), offset: 0, length: count)]
        pendingScrollOffset = 0
        return "Rewrote document (\(count) character(s))."
    }

    /// Update the document text from user editing. Clears any active
    /// highlights, since character offsets no longer line up.
    func userEdit(newText: String) {
        guard newText != text else { return }
        text = newText
        highlights.removeAll()
        pendingScrollOffset = nil
    }

    // MARK: - Internals

    private func apply(newText: String, editOffset: Int, editLength: Int) {
        text = newText
        let visibleLength = max(editLength, 1)
        let clampedLength = min(visibleLength, max(0, newText.count - editOffset))
        let highlight = DocHighlight(
            id: UUID(),
            offset: editOffset,
            length: max(clampedLength, 1)
        )
        // Only the newest change stays highlighted; older ones
        // disappear the moment the next change lands.
        highlights = [highlight]
        // Only set the scroll target if there isn't already a pending
        // one for this batch. First edit of a batch wins.
        if pendingScrollOffset == nil {
            pendingScrollOffset = editOffset
        }
    }

    private func index(at offset: Int) throws -> String.Index {
        guard offset >= 0, offset <= text.count else {
            throw ToolError("Offset \(offset) out of range 0…\(text.count).")
        }
        return text.index(text.startIndex, offsetBy: offset)
    }

    private func range(start: Int, end: Int) throws -> Range<String.Index> {
        guard start >= 0, end >= start, end <= text.count else {
            throw ToolError("Range \(start)..<\(end) is out of bounds 0…\(text.count).")
        }
        let s = text.index(text.startIndex, offsetBy: start)
        let e = text.index(text.startIndex, offsetBy: end)
        return s..<e
    }
}
