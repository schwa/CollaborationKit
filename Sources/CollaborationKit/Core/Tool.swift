import Foundation

/// An error raised by a tool that should be reported back to the model.
///
/// When a tool handler throws a value, the session converts it into an error
/// tool result so the model can observe the failure and adapt. ``ToolError``
/// provides a convenient concrete type, but any thrown `Error` is treated the
/// same way.
public struct ToolError: Error, Sendable, Equatable {
    /// A human-readable description of what went wrong.
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// A tool the model may invoke.
///
/// Conformers declare a typed, `Decodable` ``Input`` and provide an async
/// handler. The ``inputSchema`` is a hand-written JSON Schema describing the
/// shape of the input as presented to the model. Tools are stored type-erased
/// in a session via ``AnyTool``.
public protocol Tool: Sendable {
    /// The decoded input type for this tool.
    associatedtype Input: Decodable, Sendable

    /// The tool's name, as exposed to the model. Must be unique within a session.
    var name: String { get }

    /// A description of the tool's behavior, shown to the model.
    var description: String { get }

    /// A JSON Schema describing ``Input``.
    var inputSchema: JSONValue { get }

    /// Executes the tool.
    ///
    /// - Parameter input: The decoded input supplied by the model.
    /// - Returns: The textual result to send back to the model.
    /// - Throws: ``ToolError`` (or any error) to report failure to the model.
    func call(_ input: Input) async throws -> String
}

/// A type-erased ``Tool``, suitable for heterogeneous storage in a session.
public struct AnyTool: Sendable {
    /// The tool's name, as exposed to the model.
    public let name: String
    /// A description of the tool's behavior, shown to the model.
    public let description: String
    /// A JSON Schema describing the tool's input.
    public let inputSchema: JSONValue

    private let invoke: @Sendable (JSONValue) async throws -> String

    /// Erases a concrete ``Tool``, capturing its decode-and-invoke behavior.
    public init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.inputSchema = tool.inputSchema
        self.invoke = { json in
            let input = try json.decode(as: T.Input.self)
            return try await tool.call(input)
        }
    }

    /// Decodes the raw JSON input and runs the underlying tool.
    public func call(_ input: JSONValue) async throws -> String {
        try await invoke(input)
    }
}

extension Tool {
    /// Wraps this tool in an ``AnyTool``.
    public func eraseToAnyTool() -> AnyTool {
        AnyTool(self)
    }
}
