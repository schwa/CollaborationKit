import Foundation

/// A mutable text backing for the file tools.
///
/// Conformers expose the full text of a document and allow it to be replaced.
/// Two implementations ship with the package: ``FileDocument`` (backed by a file
/// on disk) and ``InMemoryDocument`` (backed by an in-memory string).
public protocol TextDocument: Sendable {
    /// Reads the full text of the document.
    func read() throws -> String

    /// Replaces the full text of the document.
    func write(_ text: String) throws
}

/// A ``TextDocument`` backed by a file on disk.
public final class FileDocument: TextDocument, @unchecked Sendable {
    /// The URL of the backing file.
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func read() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A ``TextDocument`` backed by an in-memory string.
public final class InMemoryDocument: TextDocument, @unchecked Sendable {
    private var text: String
    private let lock = NSLock()

    public init(_ text: String = "") {
        self.text = text
    }

    public func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    public func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        self.text = text
    }

    /// The current contents, for inspection by the host application.
    public var contents: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}
