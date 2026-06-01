import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// Compiler plugin entry point for NetKit's macros.
///
/// Registers every macro type the package exposes: the five HTTP verb macros
/// (`@GET`/`@POST`/`@PUT`/`@PATCH`/`@DELETE`) and the three property markers
/// (`@Path`/`@Query`/`@Body`). Generation logic is layered in by later tasks.
@main
struct NetKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        GETMacro.self,
        POSTMacro.self,
        PUTMacro.self,
        PATCHMacro.self,
        DELETEMacro.self,
        PathMacro.self,
        QueryMacro.self,
        BodyMacro.self
    ]
}
