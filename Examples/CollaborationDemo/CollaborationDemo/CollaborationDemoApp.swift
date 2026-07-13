import CollaborationKit
import CollaborationKitUI
import SwiftUI

@main
struct CollaborationDemoApp: App {
    @State private var credentials = CollaborationCredentials(
        store: KeychainCredentialStore(service: "io.schwa.CollaborationDemo"),
        defaultsKey: "collaborationDemo.backend"
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(credentials)
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

    private var settingsFooterText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version) — Built with CollaborationKit"
    }
}
