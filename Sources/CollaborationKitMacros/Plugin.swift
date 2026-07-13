import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct CollaborationKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        CollaborationToolsMacro.self,
        CollaborationToolMacro.self
    ]
}
