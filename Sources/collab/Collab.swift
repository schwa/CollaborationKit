import ArgumentParser

@main
struct Collab: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collab",
        abstract: "Collaborate with Claude on a file using tools.",
        subcommands: [Login.self, Chat.self]
    )
}
