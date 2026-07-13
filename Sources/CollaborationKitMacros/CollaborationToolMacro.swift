import SwiftSyntax
import SwiftSyntaxMacros

/// Marker peer macro. Produces no code; `CollaborationToolsMacro` reads it as
/// syntactic annotation on the enclosing type's members.
public enum CollaborationToolMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf _: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
