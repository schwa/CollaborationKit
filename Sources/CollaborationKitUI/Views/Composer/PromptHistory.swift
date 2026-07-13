import Foundation

/// Shell-style history recall state for the composer's prompt field.
///
/// Callers stash submitted prompts with ``record(_:)``. Up/down arrow
/// key handling maps to ``recallPrevious(current:)`` and
/// ``recallNext(current:)``, each of which returns the string the field
/// should display (or `nil` when there is nothing to do at that
/// endpoint).
///
/// Consecutive duplicates are skipped so pressing up repeatedly never
/// walks over the same string twice. Empty submissions are ignored.
struct PromptHistory: Equatable {
    /// Submitted prompts, oldest first.
    private(set) var entries: [String] = []

    /// Index into ``entries`` while the field is showing a recalled
    /// prompt, or `nil` when the caller is editing their live draft.
    private(set) var cursor: Int?

    /// The in-progress prompt saved on the first press of up-arrow, so
    /// down-arrow past the newest entry restores whatever the user was
    /// typing.
    private(set) var savedDraft: String = ""

    /// Records `submitted` and resets the cursor/draft to the live
    /// editing state.
    mutating func record(_ submitted: String) {
        let trimmed = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, entries.last != submitted {
            entries.append(submitted)
        }
        cursor = nil
        savedDraft = ""
    }

    /// Advances one step backward through ``entries`` and returns the
    /// string the field should now display. Returns `nil` when there is
    /// nothing older to recall.
    ///
    /// - Parameter current: The field's current text. On the first press
    ///   from the live draft it is stashed on ``savedDraft`` so
    ///   ``recallNext(current:)`` can restore it.
    mutating func recallPrevious(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let cursor {
            guard cursor > 0 else { return nil }
            self.cursor = cursor - 1
        } else {
            savedDraft = current
            cursor = entries.count - 1
        }
        return entries[cursor!]
    }

    /// Advances one step forward through ``entries``. Past the newest
    /// entry the returned string is ``savedDraft`` (and the cursor
    /// resets to the live draft). Returns `nil` when already at the
    /// live draft.
    ///
    /// - Parameter current: Unused today, accepted for API symmetry
    ///   with ``recallPrevious(current:)``.
    mutating func recallNext(current _: String) -> String? {
        guard let cursor else { return nil }
        if cursor < entries.count - 1 {
            self.cursor = cursor + 1
            return entries[self.cursor!]
        } else {
            let restored = savedDraft
            self.cursor = nil
            savedDraft = ""
            return restored
        }
    }
}
