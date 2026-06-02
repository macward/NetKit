import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - MarkerMacro

/// Shared skeleton for the property marker macros (`@Path`/`@Query`/`@Body`).
///
/// Markers are peer macros that generate no code of their own. They exist so the
/// compiler validates their placement and so the verb macro can read them as
/// attributes on stored properties — the verb macro owns custom-name handling and the
/// cross-validation diagnostics, since it alone sees the whole type.
protocol MarkerMacro: PeerMacro {}

extension MarkerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

// MARK: - Concrete markers

enum PathMacro: MarkerMacro {}
enum QueryMacro: MarkerMacro {}
enum BodyMacro: MarkerMacro {}
