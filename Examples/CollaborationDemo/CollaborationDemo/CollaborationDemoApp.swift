import CollaborationKit
import CollaborationKitUI
import SwiftUI

@main
struct CollaborationDemoApp: App {
    @State private var credentials = CollaborationCredentials(
        store: KeychainCredentialStore(service: "io.schwa.CollaborationDemo"),
        backends: Backend.allBuiltin + [.lmStudio(), .ollama()],
        defaultsKey: "collaborationDemo.backend"
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(credentials)
        }
        .commands {
            CommandGroup(after: .textEditing) {
                StopGenerationCommand()
                RollBackLastTurnCommand()
            }
        }
        #if os(macOS)
        Settings {
            VStack(spacing: 0) {
                CollaborationSettingsView()
                Text(settingsFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            .environment(credentials)
            .frame(minWidth: 520, minHeight: 420)
        }
        #endif
    }

    /// Menu items driven by the focused scene's chat session. Both read
    /// focused values published by `.collaborationSessionCommands(store:)`
    /// and disable themselves when the action isn't available.
    private struct StopGenerationCommand: View {
        @FocusedValue(\.stopGeneration) private var stop

        var body: some View {
            Button("Stop Generating") { stop?() }
                .disabled(stop == nil)
                .keyboardShortcut(".", modifiers: .command)
        }
    }

    private struct RollBackLastTurnCommand: View {
        @FocusedValue(\.rollBackLastTurn) private var rollBack

        var body: some View {
            Button("Roll Back Last Turn") { rollBack?() }
                .disabled(rollBack == nil)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    private var settingsFooterText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version) — Built with CollaborationKit"
    }
}
