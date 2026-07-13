import Foundation

/// The read/write/edit tool set for a single ``TextDocument``.
///
/// Uses ``CollaborationTools(prefix:)`` to derive tool names, descriptions,
/// and JSON schemas from the methods below, so this file has one job:
/// implement the three actual document operations. The previous hand-written
/// `ReadTool` / `WriteTool` / `EditTool` structs (with hand-maintained
/// `inputSchema` literals) were replaced by this in RFC 0003 follow-up.
///
/// The three methods are also the natural seam for unit tests, since they
/// operate directly on the ``TextDocument`` without needing the JSON layer.
@CollaborationTools
public struct FileTools: Sendable {
    /// The document the tools operate on.
    public let document: any TextDocument

    public init(document: any TextDocument) {
        self.document = document
    }

    /// Read the full current contents of the document.
    @CollaborationTool
    public func read() throws -> String {
        do {
            return try document.read()
        } catch {
            throw ToolError("Failed to read document: \(error.localizedDescription)")
        }
    }

    /// Overwrite the entire document with new content. Provide the complete new contents.
    @CollaborationTool
    public func write(content: String) throws -> String {
        do {
            try document.write(content)
            return "Wrote \(content.count) characters."
        } catch {
            throw ToolError("Failed to write document: \(error.localizedDescription)")
        }
    }

    /// Replace an exact, unique span of text in the document. `oldText` must
    /// match exactly once; include enough surrounding context to make it
    /// unique. Use `write` to create content in an empty document.
    @CollaborationTool
    public func edit(oldText: String, newText: String) throws -> String {
        let current: String
        do {
            current = try document.read()
        } catch {
            throw ToolError("Failed to read document: \(error.localizedDescription)")
        }

        let occurrences = current.components(separatedBy: oldText).count - 1
        switch occurrences {
        case 0:
            throw ToolError("`oldText` was not found in the document.")

        case 1:
            let updated = current.replacingOccurrences(of: oldText, with: newText)
            do {
                try document.write(updated)
            } catch {
                throw ToolError("Failed to write document: \(error.localizedDescription)")
            }
            return "Edit applied."

        default:
            throw ToolError("`oldText` matched \(occurrences) times; it must be unique. Add surrounding context.")
        }
    }
}

extension Array where Element == AnyTool {
    /// The standard read/write/edit tool set for a single document.
    ///
    /// Equivalent to `FileTools(document: document).collaborationTools`.
    public static func fileTools(for document: any TextDocument) -> [AnyTool] {
        FileTools(document: document).collaborationTools
    }
}
