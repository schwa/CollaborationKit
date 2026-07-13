import CollaborationKit
import Foundation
import Observation

/// Owns an ``LLMSession`` and its ``MessageMirror``, and republishes the
/// projected transcript as observable ``items``.
///
/// The heavy lifting lives elsewhere:
///
/// - ``MessageMirror`` is a pure value type that consumes ``SessionEvent``s
///   and maintains the message history, streaming overlay, error overlays,
///   and presentation metadata. Unit-testable without SwiftUI.
/// - ``TranscriptProjection`` is a pure function that turns the mirror into
///   `[ConversationItem]` for rendering.
///
/// This store is the thin @Observable @MainActor shell that wires them
/// together with the session's event pump. See `#54` for the rationale.
@preconcurrency
@MainActor
@Observable
public final class ConversationStore {
    /// The current mirror. Publicly readable so hosts can inspect the raw
    /// message history + overlays without going through the projection.
    public private(set) var mirror: MessageMirror

    /// The projected transcript rows, oldest first. Rebuilt after every
    /// mutation via ``TranscriptProjection/project(_:)``.
    public private(set) var items: [ConversationItem] = []

    /// True while a turn is in flight.
    public private(set) var isGenerating: Bool = false

    /// Cumulative token usage across the session.
    public private(set) var usage = TokenUsage()

    /// The last harness error surfaced to the user (not a tool error).
    public private(set) var lastError: String?

    /// True when the transcript has no items.
    public var isEmpty: Bool { items.isEmpty }

    /// The finalized message history. Convenience over `mirror.messages`.
    public var messages: [Message] { mirror.messages }

    // MARK: - Wiring

    private let session: LLMSession
    private let summarizeTool: @Sendable (ToolUse) -> String
    private var eventTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    @preconcurrency
    public init(
        session: LLMSession,
        summarizeTool: @escaping @Sendable (ToolUse) -> String = ConversationStore.defaultSummarize(for:)
    ) {
        self.session = session
        self.summarizeTool = summarizeTool
        self.mirror = MessageMirror()
        startPump()
    }

    /// Cancels the event pump and any in-flight send. Call when tearing
    /// down — @MainActor state can't be reached from a nonisolated deinit.
    public func cancel() {
        eventTask?.cancel()
        sendTask?.cancel()
    }

    // MARK: - Sending

    /// Starts a turn: appends the user message to the mirror, runs the
    /// agentic tool loop in a cancellable task, and streams events into
    /// ``items`` as they arrive.
    public func send(_ prompt: String, images: [ImageContent] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmed.isEmpty && images.isEmpty), !isGenerating else { return }

        lastError = nil
        let userMessage: Message = images.isEmpty
            ? .user(trimmed)
            : .user(text: trimmed, images: images)
        mirror.appendUser(userMessage)
        isGenerating = true
        reproject()

        sendTask = Task { [weak self] in
            await self?.run(trimmed, images: images)
        }
    }

    /// Cancels the in-flight turn, if any. The tool loop stops at its next
    /// cooperative cancellation point; the transcript keeps whatever has
    /// already been produced.
    public func stop() {
        guard isGenerating else { return }
        sendTask?.cancel()
    }

    private func run(_ trimmed: String, images: [ImageContent]) async {
        defer {
            isGenerating = false
            sendTask = nil
            reproject()
        }

        do {
            _ = try await session.send(text: trimmed, images: images)
        } catch is CancellationError {
            mirror.appendError("Stopped.")
        } catch {
            if Task.isCancelled {
                mirror.appendError("Stopped.")
            } else {
                mirror.appendError("\(error)")
                lastError = "\(error)"
            }
        }
        usage = await session.totalUsage
    }

    // MARK: - Event pump

    private func startPump() {
        eventTask?.cancel()
        let events = session.events
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    private func handle(_ event: SessionEvent) {
        if case .usage(let turnUsage) = event {
            usage += turnUsage
        }
        mirror.handle(event, summary: summarizeTool)
        reproject()
    }

    // MARK: - Projection

    private func reproject() {
        let (rows, livingIDs) = TranscriptProjection.project(mirror)
        mirror.compact(livingIDs: livingIDs)
        items = rows
    }
}

// MARK: - Default tool summarizer

extension ConversationStore {
    /// Default summary for a tool row's argument line.
    ///
    /// Handles the built-in `read`/`write`/`edit` file tools shipped in
    /// ``CollaborationKit``. Falls back to the tool's name for unknown
    /// tools; hosts override via `summarizeTool`.
    nonisolated public static func defaultSummarize(for use: ToolUse) -> String {
        switch use.name {
        case "read":
            return "reading the file"

        case "write":
            return "writing the file"

        case "edit":
            if case .object(let fields) = use.input,
               case .string(let old)? = fields["oldText"] {
                let snippet = old.prefix(40)
                return "replacing “\(snippet)…”"
            }
            return "editing the file"

        default:
            return use.name
        }
    }
}
