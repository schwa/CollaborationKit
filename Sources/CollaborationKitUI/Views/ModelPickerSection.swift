import CollaborationKit
import SwiftUI

/// A `Section` that shows a Picker of the models the current backend
/// advertises, filtered to chat / tool-capable ids, sorted by display name,
/// and persisted through ``CollaborationCredentials/selectModel(_:for:)``.
///
/// Drop it into any `Form` — ``CollaborationSettingsView`` already includes
/// one so the picker sits under the credentials sections by default.
public struct ModelPickerSection: View {
    @Environment(CollaborationCredentials.self)
    private var credentials

    /// Optional override for the per-model filter. When `nil`, the
    /// current ``Backend/modelFilter`` decides.
    public let filterOverride: (@Sendable (String) -> Bool)?

    @State private var models: [ModelInfo] = []
    @State private var selection: String = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    @preconcurrency
    public init(filterOverride: (@Sendable (String) -> Bool)? = nil) {
        self.filterOverride = filterOverride
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
                        if !selection.isEmpty, !models.contains(where: { $0.id == selection }) {
                            Text("\(selection) (not available)").tag(selection)
                        }
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
            Text("Model Selection")
        }
        .task(id: TaskKey(backendID: credentials.backend.id, hasCredentials: credentials.hasCredentials)) {
            await loadModels()
        }
    }

    // MARK: - Task keying

    private struct TaskKey: Equatable {
        var backendID: String
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
        let filter = filterOverride ?? credentials.backend.modelFilter
        let backend = credentials.backend
        do {
            let fetched = try await credentials.listAvailableModels()
            models = fetched
                .filter { filter($0.id.lowercased()) }
                .sorted { ($0.displayName ?? $0.id) < ($1.displayName ?? $1.id) }
            if selection.isEmpty {
                selection = models.first?.id ?? backend.defaultModel
            }
            phase = .loaded
        } catch {
            phase = .failed("Couldn't load models. Using \(credentials.selectedModel).")
        }
    }
}

#Preview {
    Form { ModelPickerSection() }
        .formStyle(.grouped)
        .environment(CollaborationCredentials())
        .frame(width: 480, height: 160)
}
