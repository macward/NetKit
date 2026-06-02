import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - VerbMacro

/// Shared implementation for the HTTP verb macros.
///
/// A verb macro is both an attached member macro (it injects the `Endpoint`
/// members the protocol does not default — `path`, `method`, plus `queryParameters`
/// and `body` when the type declares `@Query`/`@Body` properties) and an attached
/// extension macro (it adds the `: Endpoint` conformance). Concrete verbs adopt this
/// protocol and only declare which `HTTPMethod` case they map to, so all the
/// generation plumbing lives in one place.
protocol VerbMacro: MemberMacro, ExtensionMacro {
    /// The `HTTPMethod` case this verb maps to, written without the leading dot
    /// (e.g. `"get"`). Interpolated into the generated `method` member.
    static var httpMethodCase: String { get }

    /// Whether this verb carries a request body. `false` makes a `@Body` on the type a
    /// compile-time error. Defaults to `true`; only the bodiless verbs override it.
    static var allowsBody: Bool { get }
}

extension VerbMacro {
    // GET is the canonical bodiless verb the requirements name. DELETE may legitimately
    // carry a body in some APIs (HTTP permits it), so it is left body-allowing to avoid
    // false positives.
    static var allowsBody: Bool { true }
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

        // A type may carry only one verb. Each verb macro expands independently, so the
        // diagnostic is emitted once — from the earliest verb annotation — and nothing is
        // generated, leaving a single clear error instead of a pile of conflicting members.
        let verbs: [AttributeSyntax] = verbAttributes(in: declaration)
        if verbs.count > 1 {
            if isEarliestVerb(node, among: verbs) {
                context.diagnose(multipleVerbsDiagnostic(at: node))
            }
            return []
        }

        // Cross-validate the template against the markers and surface node-anchored
        // diagnostics. Generation still proceeds best-effort so the expansion stays
        // deterministic; the diagnostics are the developer-facing signal.
        let pathProps: [PathProperty] = pathProperties(in: declaration)
        for diagnostic in routeMismatchDiagnostics(template: template, pathProperties: pathProps, route: node) {
            context.diagnose(diagnostic)
        }

        // Any member the developer already wrote is left untouched: generating a
        // same-named member would be an "invalid redeclaration". This honors the
        // compatibility scenario where a verb macro coexists with a manual override
        // (`cachePolicy`, `headers`, or even `path`/`method`/`queryParameters`/`body`).
        let declaredMembers: Set<String> = declaredMemberNames(in: declaration)
        var members: [DeclSyntax] = []

        // `path` must be a computed property so runtime instance values substitute
        // the placeholders on every read, yielding a String identical to a manual
        // struct. Placeholders resolve through the `@Path` map so a custom name
        // (`{user_id}` → property `id`) interpolates the right property. `method`
        // returns the verb's HTTPMethod case.
        let placeholders: [String: String] = pathBindings(from: pathProps)
        if !declaredMembers.contains("path") {
            members.append("""
                var path: String {
                    \(raw: pathLiteral(from: template, placeholders: placeholders))
                }
                """)
        }

        if !declaredMembers.contains("method") {
            members.append("""
                var method: HTTPMethod {
                    .\(raw: httpMethodCase)
                }
                """)
        }

        // `queryParameters` and `body` are only generated when the type actually
        // declares the matching markers; otherwise the protocol's defaults
        // (`[:]` and `nil`) are inherited untouched, matching a manual struct.
        if !declaredMembers.contains("queryParameters"),
           let queryDecl: DeclSyntax = queryParametersDecl(for: queryBindings(in: declaration)) {
            members.append(queryDecl)
        }

        // A `@Body` under a bodiless verb is an error, not a member: emit the diagnostic
        // and skip generating `body` (which would be invalid for this verb anyway).
        if let body: BodyProperty = bodyProperty(in: declaration) {
            if !allowsBody {
                context.diagnose(bodyNotAllowedDiagnostic(verb: httpMethodCase, body: body, route: node))
            } else if !declaredMembers.contains("body"), let bodyDecl: DeclSyntax = bodyDecl(for: body.name) {
                members.append(bodyDecl)
            }
        }

        return members
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

        // With more than one verb on the type the member expansion already reports the
        // error and generates nothing; matching that here avoids emitting duplicate
        // `: Endpoint` extensions while the type is in an invalid state.
        guard verbAttributes(in: declaration).count <= 1 else {
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
    /// - Note: A `nil` return currently produces an empty expansion. A non-literal route
    ///   is not one of the cross-validation scenarios; surfacing a dedicated diagnostic
    ///   for it is a possible future refinement.
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
    /// Each `{placeholder}` becomes an interpolation of the property it maps to via
    /// `placeholders` (falling back to the placeholder name itself when unmapped), so
    /// `"/users/{id}"` returns the source `"/users/\(id)"`. Literal characters that
    /// would break the literal (`\` and `"`) are escaped.
    private static func pathLiteral(from template: String, placeholders: [String: String]) -> String {
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
                let property: String = placeholders[String(name)] ?? String(name)
                result += "\\(\(property))"
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
    static let allowsBody: Bool = false
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
