import CollaborationKit
import SwiftUI

/// Snapshot of a tool call's state at render time, handed to a custom
/// presenter registered on ``ToolPresenterRegistry``.
///
/// Presenters get everything the default row would draw so they can produce
/// tool-specific chrome (diagnostics list, diff view, image preview, and so
/// on) instead of the generic monospaced result blob.
public struct ToolRowContext: Sendable {
    public let name: String
    public let summary: String
    public let result: String?
    public let isError: Bool

    public init(name: String, summary: String, result: String?, isError: Bool) {
        self.name = name
        self.summary = summary
        self.result = result
        self.isError = isError
    }
}

/// Host-installed lookup that maps tool names to custom SwiftUI content for
/// their transcript rows.
///
/// Hosts create a registry, register a presenter per tool name, and inject
/// it into the environment above ``TranscriptView`` /
/// ``CollaborationChatView``. Rows for tools with no registered presenter
/// fall through to the default rendering.
///
/// ```swift
/// @State private var toolPresenters = ToolPresenterRegistry()
///     .presenter(for: "compileShader") { ctx in
///         ShaderDiagnosticsView(result: ctx.result, isError: ctx.isError)
///     }
///
/// var body: some View {
///     CollaborationChatView(store: store)
///         .environment(toolPresenters)
/// }
/// ```
///
/// The registry is a reference type so hosts can mutate it after
/// construction (e.g. inside `.task`) without re-injecting.
@MainActor
@Observable
public final class ToolPresenterRegistry {
    // Closures live on a reference-type registry, so SwiftUI compares by
    // object identity rather than trying to compare the closures. That
    // sidesteps the "closures in @Entry" trap that would otherwise
    // invalidate every row on every re-render.
    private var presenters: [String: (ToolRowContext) -> AnyView] = [:]

    public init() {}

    /// Registers a custom presenter for tool rows whose name matches
    /// `name`. Returns `self` so registrations can be chained at
    /// `@State` initialization time.
    @discardableResult
    public func presenter<V: View>(
        for name: String,
        @ViewBuilder view: @escaping (ToolRowContext) -> V
    ) -> ToolPresenterRegistry {
        presenters[name] = { AnyView(view($0)) }
        return self
    }

    /// Returns the view produced by the registered presenter for
    /// `context.name`, or `nil` if none is registered.
    public func view(for context: ToolRowContext) -> AnyView? {
        presenters[context.name].map { $0(context) }
    }
}
