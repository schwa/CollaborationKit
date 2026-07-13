@testable import CollaborationKitUI
import Foundation
import Testing

/// Unit tests for the composer's shell-style prompt-recall state
/// machine. The view logic in ``ComposerView`` is a thin adapter over
/// ``PromptHistory``; testing the value type in isolation covers the
/// interesting behavior without dragging in SwiftUI's focus / key-press
/// plumbing.
@Suite("PromptHistory")
struct PromptHistoryTests {
    @Test("record appends non-empty, distinct entries")
    func recordAppendsDistinctEntries() {
        var history = PromptHistory()
        history.record("one")
        history.record("two")
        history.record("two")
        history.record("   ")
        history.record("three")
        #expect(history.entries == ["one", "two", "three"])
    }

    @Test("recallPrevious walks backward from the newest entry, saving the live draft")
    func recallPreviousWalksBackward() {
        var history = PromptHistory()
        history.record("first")
        history.record("second")
        history.record("third")

        #expect(history.recallPrevious(current: "draft") == "third")
        #expect(history.recallPrevious(current: "third") == "second")
        #expect(history.recallPrevious(current: "second") == "first")
        // At the oldest entry, further presses no-op.
        #expect(history.recallPrevious(current: "first") == nil)
        #expect(history.savedDraft == "draft")
    }

    @Test("recallNext walks forward and restores the saved draft at the bottom")
    func recallNextRestoresDraft() {
        var history = PromptHistory()
        history.record("one")
        history.record("two")

        _ = history.recallPrevious(current: "typing…")
        _ = history.recallPrevious(current: "two")
        // Cursor is at "one"; step forward to "two", then back to draft.
        #expect(history.recallNext(current: "one") == "two")
        #expect(history.recallNext(current: "two") == "typing…")
        // Already at the live draft: nothing more to do.
        #expect(history.recallNext(current: "typing…") == nil)
        #expect(history.cursor == nil)
        #expect(history.savedDraft.isEmpty)
    }

    @Test("recallPrevious is a no-op when history is empty")
    func recallPreviousNoOpEmpty() {
        var history = PromptHistory()
        #expect(history.recallPrevious(current: "draft") == nil)
        #expect(history.cursor == nil)
        #expect(history.savedDraft.isEmpty)
    }

    @Test("record after recall resets the cursor and drops the saved draft")
    func recordResetsRecallState() {
        var history = PromptHistory()
        history.record("older")
        _ = history.recallPrevious(current: "draft")
        history.record("newer")
        #expect(history.cursor == nil)
        #expect(history.savedDraft.isEmpty)
        #expect(history.entries == ["older", "newer"])
    }
}
