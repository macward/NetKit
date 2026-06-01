import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - VerbMacro

/// Shared implementation for the HTTP verb macros.
///
/// A verb macro is both an attached member macro (it injects the `Endpoint`
/// members the protocol does not default — `path` and `method` in this task) and
/// an attached extension macro (it adds the `: Endpoint` conformance). Concrete
/// verbs adopt this protocol and only declare which `HTTPMethod` case they map to,
/// so all the generation plumbing lives in one place.
protocol VerbMacro: MemberMacro, ExtensionMacro {
    /// The `HTTPMethod` case this verb maps to, written without the leading dot
    /// (e.g. `"get"`). Interpolated into the generated `method` member.
    static var httpMethodCase: String { get }
}

// MARK: - MemberMacro

extension VerbMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let template: String = routeTemplate(from: node) else {
            return []
        }

        // `path` must be a computed property so runtime instance values substitute
        // the placeholders on every read, yielding a String identical to a manual
        // struct. `method` returns the verb's HTTPMethod case.
        let pathDecl: DeclSyntax = """
            var path: String {
                \(raw: pathLiteral(from: template))
            }
            """

        let methodDecl: DeclSyntax = """
            var method: HTTPMethod {
                .\(raw: httpMethodCase)
            }
            """

        return [pathDecl, methodDecl]
    }
}

// MARK: - ExtensionMacro

extension VerbMacro {
    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // When the developer already declared `: Endpoint` manually, the compiler
        // passes an empty `protocols` list — skip generating a duplicate conformance.
        guard !protocols.isEmpty else {
            return []
        }

        let endpointExtension: ExtensionDeclSyntax = try ExtensionDeclSyntax(
            "extension \(type.trimmed): Endpoint {}"
        )
        return [endpointExtension]
    }
}

// MARK: - Template parsing

extension VerbMacro {
    /// Extracts the route template from the verb attribute's first argument when it
    /// is a plain string literal (no interpolation). Returns `nil` otherwise —
    /// `representedLiteralValue` yields `nil` for interpolated or multi-line literals.
    ///
    /// - Note: A `nil` return currently produces an empty expansion. Surfacing a
    ///   macro-level diagnostic for a non-literal route belongs to task 005.
    private static func routeTemplate(from node: AttributeSyntax) -> String? {
        guard
            case let .argumentList(arguments) = node.arguments,
            let firstArgument = arguments.first,
            let stringLiteral = firstArgument.expression.as(StringLiteralExprSyntax.self)
        else {
            return nil
        }
        return stringLiteral.representedLiteralValue
    }

    /// Turns a route template into the *source text of a Swift string literal*,
    /// including the surrounding double-quotes, ready to splice in via `\(raw:)`.
    /// Each `{placeholder}` becomes an interpolation of the homonymous property, so
    /// `"/users/{id}"` returns the source `"/users/\(id)"`. Literal characters that
    /// would break the literal (`\` and `"`) are escaped.
    private static func pathLiteral(from template: String) -> String {
        var result: String = "\""
        var index: String.Index = template.startIndex

        while index < template.endIndex {
            let character: Character = template[index]

            if character == "{",
               let close: String.Index = template[index...].firstIndex(of: "}") {
                let nameStart: String.Index = template.index(after: index)
                let name: Substring = template[nameStart..<close]
                // An empty `{}` is not a placeholder — emitting `\()` would be invalid
                // expanded source. Treat the `{` as a literal character instead.
                guard !name.isEmpty else {
                    result.append(character)
                    index = template.index(after: index)
                    continue
                }
                result += "\\(\(name))"
                index = template.index(after: close)
                continue
            }

            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            default: result.append(character)
            }
            index = template.index(after: index)
        }

        result += "\""
        return result
    }
}

// MARK: - Concrete verbs

enum GETMacro: VerbMacro {
    static let httpMethodCase: String = "get"
}

enum POSTMacro: VerbMacro {
    static let httpMethodCase: String = "post"
}

enum PUTMacro: VerbMacro {
    static let httpMethodCase: String = "put"
}

enum PATCHMacro: VerbMacro {
    static let httpMethodCase: String = "patch"
}

enum DELETEMacro: VerbMacro {
    static let httpMethodCase: String = "delete"
}
