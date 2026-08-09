import CollaborationKit
import Foundation
import Observation

/// Bridges ``LLMSession``'s async approval closure to a SwiftUI alert.
///
/// The session calls ``request(_:)`` for every approval-gated tool use. That
/// stores the pending call and suspends on a continuation; the view observes
/// ``pending`` and drives an alert. When the user picks Allow or Deny the
/// view calls ``resolve(_:)`` which resumes the continuation with the
/// matching ``ToolApprovalDecision``.
@MainActor
@Observable
final class ApprovalGate {
    struct PendingApproval: Identifiable {
        let id = UUID()
        let use: ToolUse
        let continuation: CheckedContinuation<ToolApprovalDecision, Never>
    }

    /// Non-nil while a tool call is waiting on the user. The view binds an
    /// alert's presentation to this so the confirmation UI appears
    /// automatically.
    var pending: PendingApproval?

    /// Called by the session's approval closure. Suspends until ``resolve(_:)``
    /// runs. Multiple concurrent requests aren't expected (the session
    /// serialises tool calls); if one arrives while another is pending it
    /// pre-empts the earlier one with a deny so state stays coherent.
    ///
    /// "Always allow" needs no bookkeeping here: ``allowAlways()`` answers
    /// with ``ToolApprovalDecision/allowAlways`` and the session stops
    /// asking about that tool.
    func request(_ use: ToolUse) async -> ToolApprovalDecision {
        if let existing = pending {
            existing.continuation.resume(returning: .deny(reason: "Superseded by a new approval request."))
            pending = nil
        }
        // Cancellation-aware: if the turn is cancelled while suspended
        // here (e.g. the user hits Stop with the alert open), resolve the
        // pending request as a deny so the session's tool loop can unwind
        // instead of hanging until the alert is answered. `resolve` is a
        // no-op when `pending` is already nil, so racing a real user
        // answer is safe — first resume wins.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending = PendingApproval(use: use, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(.deny(reason: "Turn cancelled."))
            }
        }
    }

    /// Called from the alert's button actions. Resumes the suspended
    /// approval request with `decision` and clears ``pending``.
    func resolve(_ decision: ToolApprovalDecision) {
        guard let current = pending else { return }
        current.continuation.resume(returning: decision)
        pending = nil
    }

    /// Resolves the pending call with ``ToolApprovalDecision/allowAlways``,
    /// so the session runs future calls to the same tool without asking
    /// again for the rest of its lifetime.
    func allowAlways() {
        resolve(.allowAlways)
    }
}
