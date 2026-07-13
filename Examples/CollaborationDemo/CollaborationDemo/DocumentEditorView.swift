import SwiftUI

/// Full-window text editor backed by ``DemoDoc``. The user can freely
/// type; the assistant edits the same buffer through the DemoDoc
/// tools. Assistant edits highlight briefly and fade out.
struct DocumentEditorView: View {
    @Bindable var doc: DemoDoc

    /// Attributed mirror of ``DemoDoc.text``. Rebuilt when the doc
    /// changes or when highlights need to fade a tick further.
    @State private var attributed = AttributedString()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: doc.highlights.isEmpty)) { context in
            TextEditor(text: $attributed)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .task(id: docSignature) {
                    rebuild(now: context.date)
                }
                .onAppear {
                    rebuild(now: context.date)
                }
                .onChange(of: context.date) { _, now in
                    doc.expireHighlights(now: now)
                    rebuild(now: now)
                }
                .onChange(of: attributed) { _, new in
                    let plain = String(new.characters)
                    if plain != doc.text {
                        doc.userEdit(newText: plain)
                    }
                }
        }
    }

    /// Cheap fingerprint of doc state that should force a rebuild.
    /// AttributedString equality is expensive; a length+highlight-id
    /// summary is enough to know a tool edit landed.
    private var docSignature: String {
        var out = "\(doc.text.count):\(doc.highlights.count)"
        if let last = doc.highlights.last {
            out += ":\(last.id.uuidString)"
        }
        return out
    }

    private func rebuild(now: Date) {
        var attr = AttributedString(doc.text)
        let lifetime = DemoDoc.highlightLifetime
        for highlight in doc.highlights {
            let age = now.timeIntervalSince(highlight.createdAt)
            guard age < lifetime else { continue }
            let alpha = max(0.0, 1.0 - age / lifetime)
            guard let range = range(in: attr, offset: highlight.offset, length: highlight.length) else { continue }
            attr[range].backgroundColor = Color.yellow.opacity(alpha * 0.55)
        }
        // Skip writes when nothing about the plain text changed and
        // there are no highlights to fade — avoids caret jumps.
        if attr == attributed { return }
        attributed = attr
    }

    private func range(
        in attr: AttributedString,
        offset: Int,
        length: Int
    ) -> Range<AttributedString.Index>? {
        let chars = attr.characters
        let total = chars.count
        guard offset >= 0, offset <= total else { return nil }
        let clampedLength = max(length, 1)
        let end = min(total, offset + clampedLength)
        guard end > offset else { return nil }
        let start = chars.index(chars.startIndex, offsetBy: offset)
        let stop = chars.index(chars.startIndex, offsetBy: end)
        return start..<stop
    }
}

#Preview {
    DocumentEditorView(doc: DemoDoc())
        .frame(width: 720, height: 520)
}
