import SwiftUI
import CollaborationKit
import CollaborationKitUI

struct ContentView: View {
    @Environment(CollaborationCredentials.self) private var credentials
    @State private var chat: ChatSession?
    @State private var buildError: String?

    var body: some View {
        Group {
            if let chat {
                CollaborationChatView(store: chat.store)
            } else if let buildError {
                ContentUnavailableView {
                    Label("Couldn't start chat", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(buildError)
                }
            } else {
                ContentUnavailableView {
                    Label("Sign in to Chat", systemImage: "key.horizontal")
                } description: {
                    Text("Add credentials for \(credentials.backend.displayName) in Settings (⌘,), then reopen this window.")
                } actions: {
                    #if os(macOS)
                    SettingsLink { Text("Open Settings…") }
                    #endif
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .task(id: taskKey) { rebuildChat() }
    }

    // Rebuilds the chat session when the backend or credential state changes.
    private var taskKey: String {
        "\(credentials.backend.rawValue)-\(credentials.hasCredentials)"
    }

    private func rebuildChat() {
        chat = nil
        buildError = nil
        guard credentials.hasCredentials else { return }
        do {
            chat = try ChatSession(credentials: credentials)
        } catch {
            buildError = error.localizedDescription
        }
    }
}

/// Holds the `LLMSession` + `ConversationStore` for one chat window so both
/// stay alive together.
@MainActor
private final class ChatSession {
    let session: LLMSession
    let store: ConversationStore

    init(credentials: CollaborationCredentials) throws {
        let provider = try credentials.makeProvider(maxTokens: 4_096)
        self.session = LLMSession(
            provider: provider,
            system: "You are a helpful assistant collaborating with the user."
        )
        self.store = ConversationStore(session: session)
    }
}
