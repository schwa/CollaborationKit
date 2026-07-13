import SwiftUI
import CollaborationKit
import CollaborationKitUI

struct ContentView: View {
    @Environment(CollaborationCredentials.self) private var credentials

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .imageScale(.large)
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("CollaborationDemo")
                .font(.title2)

            GroupBox {
                LabeledContent("Backend", value: credentials.backend.displayName)
                LabeledContent("Credentials",
                               value: credentials.hasCredentials ? "Present" : "Missing")
                    .foregroundStyle(credentials.hasCredentials ? .green : .secondary)
            }
            .frame(maxWidth: 320)

            Text("Open Settings (⌘,) to add an API key or sign in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
