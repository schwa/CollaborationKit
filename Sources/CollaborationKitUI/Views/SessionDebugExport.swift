import CollaborationKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Action

/// A callable value that triggers a session debug-log export.
///
/// Attached to the environment and to the focused scene by
/// ``SwiftUICore/View/collaborationDebugExport(store:model:defaultFilename:userInfo:)``.
/// Descendant views (typically the composer's ladybug affordance) read the
/// action from ``EnvironmentValues/exportDebugLogAction``; a `File` menu
/// command reads it from ``FocusedValues/exportDebugLog``. Invoking the
/// action asks the view that installed the modifier to present a file
/// exporter for the current transcript.
public struct ExportDebugLogAction: Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    /// Triggers the export. Must be called on the main actor.
    @MainActor
    public func callAsFunction() {
        handler()
    }
}

// MARK: - Focused / Environment plumbing

extension FocusedValues {
    /// The active session-debug-export action for the focused scene, if any.
    ///
    /// A host wires a `File → Export Debug Log…` menu command by reading
    /// this value and invoking it:
    ///
    /// ```swift
    /// CommandGroup(after: .saveItem) {
    ///     ExportDebugLogCommand()
    /// }
    ///
    /// struct ExportDebugLogCommand: View {
    ///     @FocusedValue(\.exportDebugLog) private var export
    ///     var body: some View {
    ///         Button("Export Debug Log…") { export?() }
    ///             .disabled(export == nil)
    ///             .keyboardShortcut("E", modifiers: [.command, .shift])
    ///     }
    /// }
    /// ```
    @Entry public var exportDebugLog: ExportDebugLogAction? = nil
}

extension EnvironmentValues {
    /// The session-debug-export action available to descendants, if any.
    ///
    /// Set by ``SwiftUICore/View/collaborationDebugExport(store:model:defaultFilename:userInfo:)``.
    /// Views inside the modified subtree read this to expose their own
    /// export affordance without owning the file-exporter state.
    @Entry public var exportDebugLogAction: ExportDebugLogAction? = nil
}

// MARK: - Modifier

/// The view modifier that owns the file-exporter state, publishes the
/// focused-scene action, and exposes the environment action.
///
/// Instances are created by
/// ``SwiftUICore/View/collaborationDebugExport(store:model:defaultFilename:userInfo:)``;
/// the type is `public` so hosts can `.modifier(SessionDebugExportModifier(...))`
/// directly if they prefer that spelling.
public struct SessionDebugExportModifier: ViewModifier {
    public var store: ConversationStore
    public var model: String?
    public var defaultFilename: @Sendable () -> String
    public var userInfo: @Sendable () -> [String: String]

    @State private var isPresented = false
    @State private var payload: SessionExport?

    public init(
        store: ConversationStore,
        model: String? = nil,
        defaultFilename: @escaping @Sendable () -> String = { Self.timestampedFilename() },
        userInfo: @escaping @Sendable () -> [String: String] = { [:] }
    ) {
        self.store = store
        self.model = model
        self.defaultFilename = defaultFilename
        self.userInfo = userInfo
    }

    public func body(content: Content) -> some View {
        let action = ExportDebugLogAction { @MainActor in
            payload = store.buildExport(model: model, userInfo: userInfo())
            isPresented = true
        }

        content
            .environment(\.exportDebugLogAction, action)
            .focusedSceneValue(\.exportDebugLog, action)
            .fileExporter(
                isPresented: $isPresented,
                item: payload,
                contentTypes: [.json],
                defaultFilename: defaultFilename()
            ) { _ in
                // Success/failure is up to the host to observe if it cares;
                // the modifier's job is to present the sheet.
                payload = nil
            }
    }

    /// The default filename: `collaboration-debug-YYYYMMDD-HHMMSS.json`.
    ///
    /// Filesystem-safe on every platform we ship: no colons, no spaces.
    public nonisolated static func timestampedFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "collaboration-debug-\(formatter.string(from: Date())).json"
    }
}

extension View {
    /// Installs a session debug-log export point on this view.
    ///
    /// The modifier owns the file-exporter state, publishes an
    /// ``ExportDebugLogAction`` to descendants via
    /// ``EnvironmentValues/exportDebugLogAction``, and to the focused scene
    /// via ``FocusedValues/exportDebugLog``. Attach it once at the chat
    /// container (or higher, if you want a `File` menu command to reach
    /// it) and the composer's built-in ladybug button (enabled with
    /// ``SwiftUICore/View/collaborationShowsDebugExportButton(_:)``) and
    /// any `@FocusedValue(\.exportDebugLog)` menu command will both
    /// trigger the same export.
    ///
    /// - Parameters:
    ///   - store: The ``ConversationStore`` whose transcript to export.
    ///   - model: Optional model identifier to embed in the payload.
    ///   - defaultFilename: Called each time the exporter is presented, so
    ///     the timestamp reflects "now" rather than the moment the modifier
    ///     was installed. Defaults to
    ///     ``SessionDebugExportModifier/timestampedFilename()``.
    ///   - userInfo: Called each time the export is built, so the host can
    ///     drop in fresh metadata (current shader source, build id, active
    ///     panel, whatever). Defaults to empty.
    public func collaborationDebugExport(
        store: ConversationStore,
        model: String? = nil,
        defaultFilename: @escaping @Sendable () -> String = { SessionDebugExportModifier.timestampedFilename() },
        userInfo: @escaping @Sendable () -> [String: String] = { [:] }
    ) -> some View {
        modifier(SessionDebugExportModifier(
            store: store,
            model: model,
            defaultFilename: defaultFilename,
            userInfo: userInfo
        ))
    }
}
