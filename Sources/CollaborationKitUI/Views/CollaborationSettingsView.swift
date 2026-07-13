import SwiftUI
import CollaborationKit

/// Drop-in settings view: backend picker plus the credential section for
/// whichever backend is selected.
///
/// Requires a ``CollaborationCredentials`` in the environment. Suitable for
/// use inside a macOS `Settings` scene, an iOS pushed detail view, or embedded
/// in any host settings surface.
///
/// ```swift
/// Settings {
///     CollaborationSettingsView()
///         .environment(credentials)
///         .frame(minWidth: 480, minHeight: 320)
/// }
/// ```
public struct CollaborationSettingsView: View {
    @Environment(CollaborationCredentials.self) private var credentials

    /// Which backends to expose in the picker. Defaults to all cases.
    public let backends: [CollaborationBackend]

    public init(backends: [CollaborationBackend] = CollaborationBackend.allCases) {
        self.backends = backends
    }

    public var body: some View {
        @Bindable var bindable = credentials
        Form {
            Section {
                Picker("Provider", selection: $bindable.backend) {
                    ForEach(backends) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
            } footer: {
                Text("Choose which provider CollaborationKit talks to. Each provider has its own credentials.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            switch credentials.backend {
            case .claudeSubscription:
                AnthropicOAuthSection()

            case .anthropicAPI:
                AnthropicAPIKeySection()

            case .openAI:
                OpenAIAPIKeySection()
            }

            ModelPickerSection()
        }
        .formStyle(.grouped)
    }
}

#Preview("Settings — Claude subscription") {
    CollaborationSettingsView()
        .environment(CollaborationCredentials())
        .frame(width: 520, height: 360)
}
