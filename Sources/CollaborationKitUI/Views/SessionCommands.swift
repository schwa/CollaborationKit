import CollaborationKit
import SwiftUI

// MARK: - Actions

/// A callable value that cancels the in-flight turn.
///
/// Published to the focused scene as ``FocusedValues/stopGeneration`` and to
/// descendants as ``EnvironmentValues/stopGenerationAction`` by
/// ``SwiftUICore/View/collaborationSessionCommands(store:)``. Both are `nil`
/// when no turn is running, so a menu command can bind `.disabled` straight
/// to the absence of the value.
public struct StopGenerationAction: Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    /// Stops the current turn. Must be called on the main actor.
    @MainActor
    public func callAsFunction() {
        handler()
    }
}

/// A callable value that rolls the session back through the most recent
/// user prompt that carries a snapshot.
///
/// Published to the focused scene as ``FocusedValues/rollBackLastTurn`` and
/// to descendants as ``EnvironmentValues/rollBackLastTurnAction`` by
/// ``SwiftUICore/View/collaborationSessionCommands(store:)``. Both are `nil`
/// when there is nothing to roll back to.
public struct RollBackLastTurnAction: Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    /// Performs the rollback. Must be called on the main actor.
    @MainActor
    public func callAsFunction() {
        handler()
    }
}

// MARK: - Focused / Environment plumbing

extension FocusedValues {
    /// The stop-generation action for the focused scene, or `nil` when no
    /// turn is running.
    ///
    /// ```swift
    /// CommandGroup(after: .textEditing) {
    ///     StopGenerationCommand()
    /// }
    ///
    /// struct StopGenerationCommand: View {
    ///     @FocusedValue(\.stopGeneration) private var stop
    ///     var body: some View {
    ///         Button("Stop Generating") { stop?() }
    ///             .disabled(stop == nil)
    ///             .keyboardShortcut(".", modifiers: .command)
    ///     }
    /// }
    /// ```
    @Entry public var stopGeneration: StopGenerationAction? = nil

    /// The roll-back-last-turn action for the focused scene, or `nil` when
    /// there is no rollback point.
    @Entry public var rollBackLastTurn: RollBackLastTurnAction? = nil
}

extension EnvironmentValues {
    /// The stop-generation action available to descendants, if any.
    @Entry public var stopGenerationAction: StopGenerationAction? = nil

    /// The roll-back-last-turn action available to descendants, if any.
    @Entry public var rollBackLastTurnAction: RollBackLastTurnAction? = nil
}

// MARK: - Modifier

/// Publishes a ``ConversationStore``'s menu-driveable actions to the focused
/// scene and to the environment.
///
/// Created by ``SwiftUICore/View/collaborationSessionCommands(store:)``; the
/// type is `public` so hosts can `.modifier(SessionCommandsModifier(store:))`
/// directly if they prefer that spelling.
public struct SessionCommandsModifier: ViewModifier {
    public var store: ConversationStore

    public init(store: ConversationStore) {
        self.store = store
    }

    public func body(content: Content) -> some View {
        // Both values are computed from observable store state, so the
        // modifier re-evaluates (and the menu items enable/disable) as the
        // turn starts and finishes.
        let stop = store.isGenerating ? StopGenerationAction { @MainActor in store.stop() } : nil
        let rollBackTarget = store.lastRollbackTarget
        let rollBack = rollBackTarget.map { target in
            RollBackLastTurnAction { @MainActor in store.rollBack(through: target) }
        }

        content
            .environment(\.stopGenerationAction, stop)
            .environment(\.rollBackLastTurnAction, rollBack)
            .focusedSceneValue(\.stopGeneration, stop)
            .focusedSceneValue(\.rollBackLastTurn, rollBack)
    }
}

extension View {
    /// Publishes the session's stop and rollback actions for menu commands.
    ///
    /// Attach once per chat scene, alongside
    /// ``SwiftUICore/View/collaborationDebugExport(store:model:defaultFilename:userInfo:)``.
    /// A host then adds `File`/`Edit` menu items that read
    /// ``FocusedValues/stopGeneration`` and ``FocusedValues/rollBackLastTurn``;
    /// both are `nil` when the corresponding action is unavailable, which is
    /// the signal to disable the menu item.
    ///
    /// - Parameter store: The ``ConversationStore`` the commands drive.
    public func collaborationSessionCommands(store: ConversationStore) -> some View {
        modifier(SessionCommandsModifier(store: store))
    }
}
