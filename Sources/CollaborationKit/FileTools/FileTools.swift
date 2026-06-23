import Foundation

/// A tool that reads the full contents of a ``TextDocument``.
public struct ReadTool: Tool {
    public struct Input: Decodable, Sendable {
        public init() {}
    }

    private let document: TextDocument

    public init(document: TextDocument) {
        self.document = document
    }

    public var name: String { "read" }
    public var description: String { "Read the full current contents of the document." }
    public var inputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([:])
        ])
    }

    public func call(_: Input) throws -> String {
        do {
            return try document.read()
        } catch {
            throw ToolError("Failed to read document: \(error.localizedDescription)")
        }
    }
}

/// A tool that overwrites the full contents of a ``TextDocument``.
public struct WriteTool: Tool {
    public struct Input: Decodable, Sendable {
        public let content: String
    }

    private let document: TextDocument

    public init(document: TextDocument) {
        self.document = document
    }

    public var name: String { "write" }
    public var description: String {
        "Overwrite the entire document with new content. Provide the complete new contents."
    }
    public var inputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "content": .object([
                    "type": "string",
                    "description": "The complete new contents of the document."
                ])
            ]),
            "required": .array(["content"])
        ])
    }

    public func call(_ input: Input) throws -> String {
        do {
            try document.write(input.content)
            return "Wrote \(input.content.count) characters."
        } catch {
            throw ToolError("Failed to write document: \(error.localizedDescription)")
        }
    }
}

/// A tool that performs an exact, unique string replacement within a document.
///
/// The `oldText` must appear exactly once in the document; otherwise the edit is
/// rejected with an error result so the model can supply more context.
public struct EditTool: Tool {
    public struct Input: Decodable, Sendable {
        public let oldText: String
        public let newText: String
    }

    private let document: TextDocument

    public init(document: TextDocument) {
        self.document = document
    }

    public var name: String { "edit" }
    public var description: String {
        """
        Replace an exact, unique span of text in the document. \
        `oldText` must match exactly once; include enough surrounding context to \
        make it unique. Use `write` to create content in an empty document.
        """
    }
    public var inputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "oldText": .object([
                    "type": "string",
                    "description": "The exact text to replace. Must be unique in the document."
                ]),
                "newText": .object([
                    "type": "string",
                    "description": "The replacement text."
                ])
            ]),
            "required": .array(["oldText", "newText"])
        ])
    }

    public func call(_ input: Input) throws -> String {
        let current: String
        do {
            current = try document.read()
        } catch {
            throw ToolError("Failed to read document: \(error.localizedDescription)")
        }

        let occurrences = current.components(separatedBy: input.oldText).count - 1
        switch occurrences {
        case 0:
            throw ToolError("`oldText` was not found in the document.")

        case 1:
            let updated = current.replacingOccurrences(of: input.oldText, with: input.newText)
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
    public static func fileTools(for document: TextDocument) -> [AnyTool] {
        [
            ReadTool(document: document).eraseToAnyTool(),
            WriteTool(document: document).eraseToAnyTool(),
            EditTool(document: document).eraseToAnyTool()
        ]
    }
}
