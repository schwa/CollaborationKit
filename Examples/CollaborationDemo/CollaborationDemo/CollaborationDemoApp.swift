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
            CollaborationSettingsView()
                .environment(credentials)
                .frame(minWidth: 520, minHeight: 380)
        }
        #endif
    }
}
