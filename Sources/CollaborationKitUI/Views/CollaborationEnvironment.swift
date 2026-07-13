import CollaborationKit
import SwiftUI

// MARK: - View-slot wrapper

/// Type-erased view-builder stored in the SwiftUI environment.
///
/// Used to plumb host-supplied placeholders and headers
/// (``EnvironmentValues/collaborationEmptyPlaceholder``,
/// ``EnvironmentValues/collaborationMissingCredentialsPlaceholder``,
/// ``EnvironmentValues/collaborationComposerHeader``) through the
/// environment instead of forcing hosts to thread them through initializer
/// generics on every chat view in the module.
public struct CollaborationViewSlot: Sendable {
    private let build: @MainActor @Sendable () -> AnyView

    init(build: @escaping @MainActor @Sendable () -> AnyView) {
        self.build = build
    }

    /// Materializes the stored view. Callers gate their surrounding view
    /// on the slot being non-`nil` in the environment, so this is only
    /// invoked when the host actually supplied content.
    @MainActor
    func content() -> AnyView {
        build()
    }
}

// MARK: - EnvironmentValues

extension EnvironmentValues {
    /// The empty-transcript placeholder installed by
    /// ``SwiftUICore/View/collaborationEmptyPlaceholder(_:)``. When `nil`,
    /// ``TranscriptView`` draws its generic default.
    @Entry public var collaborationEmptyPlaceholder: CollaborationViewSlot? = nil

    /// The composer caption view installed by
    /// ``SwiftUICore/View/collaborationComposerHeader(_:)``. When `nil`,
    /// ``ComposerView`` draws no header. Hosts typically render the active
    /// backend and model here.
    @Entry public var collaborationComposerHeader: CollaborationViewSlot? = nil

    /// The missing-credentials placeholder installed by
    /// ``SwiftUICore/View/collaborationMissingCredentialsPlaceholder(_:)``.
    /// When `nil`, ``CollaborationChatView`` draws its generic
    /// "Sign in to Continue" fallback.
    @Entry public var collaborationMissingCredentialsPlaceholder: CollaborationViewSlot? = nil

    /// Whether the composer draws a ladybug affordance that invokes the
    /// ambient ``ExportDebugLogAction``. Installed by
    /// ``SwiftUICore/View/collaborationShowsDebugExportButton(_:)``.
    /// Defaults to `false` so hosts opt in explicitly.
    @Entry public var collaborationShowsDebugExportButton: Bool = false

    /// The composer prompt-field border style. Installed by
    /// ``SwiftUICore/View/collaborationComposerBorderStyle(_:)``. Defaults
    /// to ``ComposerBorderStyle/plain``.
    @Entry public var collaborationComposerBorderStyle: ComposerBorderStyle = .plain
}

// MARK: - View modifiers

extension View {
    /// Installs a host-supplied placeholder shown by ``TranscriptView`` when
    /// the transcript is empty and no turn is in flight. Hosts should
    /// override the default to describe what their assistant actually does.
    public func collaborationEmptyPlaceholder<Content: View>(
        @ViewBuilder _ content: @escaping @MainActor @Sendable () -> Content
    ) -> some View {
        environment(
            \.collaborationEmptyPlaceholder,
            CollaborationViewSlot { AnyView(content()) }
        )
    }

    /// Installs a host-supplied caption view drawn above the composer's
    /// prompt field. Typically shows the active backend and model.
    public func collaborationComposerHeader<Content: View>(
        @ViewBuilder _ content: @escaping @MainActor @Sendable () -> Content
    ) -> some View {
        environment(
            \.collaborationComposerHeader,
            CollaborationViewSlot { AnyView(content()) }
        )
    }

    /// Installs a host-supplied placeholder shown by
    /// ``CollaborationChatView`` when the ambient
    /// ``CollaborationCredentials`` reports no stored credentials for the
    /// current backend.
    public func collaborationMissingCredentialsPlaceholder<Content: View>(
        @ViewBuilder _ content: @escaping @MainActor @Sendable () -> Content
    ) -> some View {
        environment(
            \.collaborationMissingCredentialsPlaceholder,
            CollaborationViewSlot { AnyView(content()) }
        )
    }

    /// Enables (or disables) the composer's built-in ladybug affordance that
    /// triggers the ambient ``ExportDebugLogAction`` (installed by
    /// ``SwiftUICore/View/collaborationDebugExport(store:model:defaultFilename:userInfo:)``).
    /// The button hides itself when no action is available, so leaving this
    /// on in production is safe.
    public func collaborationShowsDebugExportButton(_ shows: Bool = true) -> some View {
        environment(\.collaborationShowsDebugExportButton, shows)
    }

    /// Sets the composer prompt-field border style.
    public func collaborationComposerBorderStyle(_ style: ComposerBorderStyle) -> some View {
        environment(\.collaborationComposerBorderStyle, style)
    }
}
