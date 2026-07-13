import CollaborationKit
import SwiftUI

/// Drop-in settings view: backend picker plus the credential section for
/// whichever backend is selected.
public struct CollaborationSettingsView: View {
    @Environment(CollaborationCredentials.self)
    private var credentials

    public init() {}

    public var body: some View {
        @Bindable var bindable = credentials
        Form {
            Section {
                Picker("Provider", selection: $bindable.backend) {
                    ForEach(credentials.backends) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
            } header: {
                Text("AI Service")
            } footer: {
                Text("Choose which provider CollaborationKit talks to. Each provider has its own credentials.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Which credential section to show is a per-backend concern; the
            // built-in three map to the sections shipped in this target.
            switch credentials.backend.id {
            case Backend.claudeSubscription.id:
                AnthropicOAuthSection()

            case Backend.anthropicAPI.id:
                AnthropicAPIKeySection()

            case Backend.openAI.id:
                OpenAIAPIKeySection()

            default:
                Section("Credentials") {
                    Text("This backend doesn't ship a built-in credentials section. Add one for '\(credentials.backend.displayName)' if you want in-app entry.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
