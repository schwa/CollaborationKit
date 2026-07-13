import SwiftUI
import CollaborationKit

/// A `Section` that shows a Picker of the models the current backend
/// advertises, filtered to chat / tool-capable ids, sorted by display name,
/// and persisted through ``CollaborationCredentials/selectModel(_:for:)``.
///
/// Drop it into any `Form` — ``CollaborationSettingsView`` already includes
/// one so the picker sits under the credentials sections by default.
public struct ModelPickerSection: View {
    @Environment(CollaborationCredentials.self) private var credentials

    /// A filter for which model ids to expose. Defaults to
    /// ``ModelPickerSection/defaultChatModelFilter(_:for:)`` which drops
    /// obvious non-chat ids (embeddings, audio, image, moderation, dated
    /// snapshots). Return `true` to keep an id.
    public let filter: (String, CollaborationBackend) -> Bool

    @State private var models: [ModelInfo] = []
    @State private var selection: String = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    public init(
        filter: @escaping (String, CollaborationBackend) -> Bool = ModelPickerSection.defaultChatModelFilter(_:for:)
    ) {
        self.filter = filter
    }

    public var body: some View {
        Section {
            switch phase {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Loading models…") }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .idle, .loaded:
                Picker("Model", selection: $selection) {
                    if models.isEmpty {
                        // No catalog available: show the default so the
                        // Picker still binds to a non-empty tag.
                        Text(credentials.backend.defaultModel).tag(selection)
                    } else {
                        ForEach(models) { model in
                            Text(model.displayName ?? model.id).tag(model.id)
                        }
                    }
                }
                .onChange(of: selection) { _, newValue in
                    credentials.selectModel(newValue)
                }
            }
        } header: {
            Text("Model")
        }
        .task(id: TaskKey(backend: credentials.backend, hasCredentials: credentials.hasCredentials)) {
            await loadModels()
        }
    }

    // MARK: - Task keying

    private struct TaskKey: Equatable {
        var backend: CollaborationBackend
        var hasCredentials: Bool
    }

    // MARK: - Loading

    private func loadModels() async {
        selection = credentials.selectedModel
        guard credentials.hasCredentials else {
            phase = .idle
            return
        }
        phase = .loading
        do {
            let fetched = try await credentials.listAvailableModels()
            let backend = credentials.backend
            models = fetched
                .filter { filter($0.id, backend) }
                .sorted { ($0.displayName ?? $0.id) < ($1.displayName ?? $1.id) }
            if !models.contains(where: { $0.id == selection }) {
                selection = models.first?.id ?? backend.defaultModel
            }
            phase = .loaded
        } catch {
            phase = .failed("Couldn't load models. Using \(credentials.selectedModel).")
        }
    }

    // MARK: - Default filter

    /// A heuristic for chat / tool-capable model ids.
    ///
    /// Drops:
    /// - Dated snapshot pins (`…-2025-12-11`).
    /// - OpenAI's non-text families (audio, image, realtime, embeddings, etc.).
    /// - Non-`claude-*` ids on Anthropic backends.
    ///
    /// Extend or replace by supplying your own closure to
    /// ``ModelPickerSection/init(filter:)``.
    public nonisolated static func defaultChatModelFilter(_ id: String, for backend: CollaborationBackend) -> Bool {
        let lower = id.lowercased()
        if hasDatedSnapshotSuffix(lower) { return false }
        switch backend {
        case .claudeSubscription, .anthropicAPI:
            return lower.hasPrefix("claude-")

        case .openAI:
            let excluded = ["audio", "image", "realtime", "transcribe", "tts",
                            "whisper", "embedding", "moderation", "search",
                            "dall-e", "codex", "computer-use"]
            if excluded.contains(where: lower.contains) { return false }
            return lower.hasPrefix("gpt-") || lower.hasPrefix("chatgpt")
                || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4")
        }
    }

    /// True if `id` ends in a `-YYYY-MM-DD` snapshot date.
    private nonisolated static func hasDatedSnapshotSuffix(_ id: String) -> Bool {
        id.wholeMatch(of: /.*-\d{4}-\d{2}-\d{2}/) != nil
    }
}
