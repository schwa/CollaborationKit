import ArgumentParser

// The CLI uses getpass, readLine, and stdout — macOS-only. On other platforms
// the executable target still needs an entry point to link, so provide a
// minimal stub that does nothing.
#if os(macOS)

@main
struct Collab: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collab-cli",
        abstract: "Collaborate with Claude on a file using tools.",
        subcommands: [Login.self, Chat.self]
    )
}

#else

@main
struct Collab {
    static func main() {
        fatalError("collab-cli is macOS-only.")
    }
}

#endif
