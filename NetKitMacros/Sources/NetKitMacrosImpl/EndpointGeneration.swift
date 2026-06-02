import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Property collection

/// A stored property annotated with `@Query`, resolved to the data the generator needs.
struct QueryBinding {
    /// The Swift property name to read at runtime.
    let propertyName: String
    /// The query key to emit — the custom name when supplied, else the property name.
    let key: String
    /// Whether the property type is an `Optional` (`T?`), whose `nil` is omitted.
    let isOptional: Bool
    /// Whether the property type is an `Array` (`[T]`), emitted by repeating the key.
    let isArray: Bool
}

/// A stored property annotated with `@Path`, retaining the syntax nodes the diagnostics
/// need to anchor messages and build FixIts.
struct PathProperty {
    /// The placeholder name this property covers — the custom name when supplied, else
    /// the property name.
    let key: String
    /// The Swift property name to interpolate into the path.
    let name: String
    /// The property declaration, anchor for the orphan-`@Path` diagnostic.
    let variable: VariableDeclSyntax
    /// The `@Path` attribute, removed by the orphan diagnostic's FixIt.
    let attribute: AttributeSyntax
}

/// A stored property annotated with `@Body`, retaining the syntax nodes the bodiless-verb
/// diagnostic needs.
struct BodyProperty {
    /// The Swift property name returned as the request body.
    let name: String
    /// The property declaration the FixIt edits.
    let variable: VariableDeclSyntax
    /// The `@Body` attribute, removed by the bodiless-verb diagnostic's FixIt.
    let attribute: AttributeSyntax
}

/// All `@Path`-marked properties of the type, in declaration order, with their syntax nodes.
func pathProperties(in declaration: some DeclGroupSyntax) -> [PathProperty] {
    var properties: [PathProperty] = []
    for member in declaration.memberBlock.members {
        guard
            let variable: VariableDeclSyntax = member.decl.as(VariableDeclSyntax.self),
            let attribute: AttributeSyntax = markerAttribute(named: "Path", on: variable),
            let name: String = propertyName(of: variable)
        else {
            continue
        }
        let key: String = customName(from: attribute) ?? name
        properties.append(PathProperty(key: key, name: name, variable: variable, attribute: attribute))
    }
    return properties
}

/// The `@Path` placeholder map keyed by the *placeholder* name (custom name when
/// supplied, else the property name) to the Swift *property* name to interpolate.
func pathBindings(from properties: [PathProperty]) -> [String: String] {
    var map: [String: String] = [:]
    for property in properties {
        map[property.key] = property.name
    }
    return map
}

/// All `@Query`-marked properties of the type, in declaration order.
func queryBindings(in declaration: some DeclGroupSyntax) -> [QueryBinding] {
    var bindings: [QueryBinding] = []
    for member in declaration.memberBlock.members {
        guard
            let variable: VariableDeclSyntax = member.decl.as(VariableDeclSyntax.self),
            let attribute: AttributeSyntax = markerAttribute(named: "Query", on: variable),
            let name: String = propertyName(of: variable)
        else {
            continue
        }
        let key: String = customName(from: attribute) ?? name
        let (isOptional, isArray): (Bool, Bool) = classify(propertyType(of: variable))
        bindings.append(
            QueryBinding(propertyName: name, key: key, isOptional: isOptional, isArray: isArray)
        )
    }
    return bindings
}

/// The single `@Body`-marked property with its syntax nodes, or `nil` when the type has none.
func bodyProperty(in declaration: some DeclGroupSyntax) -> BodyProperty? {
    for member in declaration.memberBlock.members {
        guard
            let variable: VariableDeclSyntax = member.decl.as(VariableDeclSyntax.self),
            let attribute: AttributeSyntax = markerAttribute(named: "Body", on: variable),
            let name: String = propertyName(of: variable)
        else {
            continue
        }
        return BodyProperty(name: name, variable: variable, attribute: attribute)
    }
    return nil
}

/// The names of the stored/computed properties and functions the type already declares.
///
/// Used to honor manual overrides: when the developer writes a member the macro would
/// otherwise generate (`path`, `method`, `queryParameters`, `body`) — or any of the
/// protocol-default members like `cachePolicy`/`headers` — the macro skips generating it
/// so the hand-written one is respected without a redeclaration conflict.
func declaredMemberNames(in declaration: some DeclGroupSyntax) -> Set<String> {
    var names: Set<String> = []
    for member in declaration.memberBlock.members {
        if let variable: VariableDeclSyntax = member.decl.as(VariableDeclSyntax.self) {
            for binding in variable.bindings {
                if let identifier: IdentifierPatternSyntax = binding.pattern.as(IdentifierPatternSyntax.self) {
                    names.insert(identifier.identifier.text)
                }
            }
        } else if let function: FunctionDeclSyntax = member.decl.as(FunctionDeclSyntax.self) {
            names.insert(function.name.text)
        }
    }
    return names
}

/// The simple names of the HTTP verb macros, used to detect more than one on a type.
private let verbAttributeNames: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]

/// The verb-macro attributes applied to the type, in source order.
func verbAttributes(in declaration: some DeclGroupSyntax) -> [AttributeSyntax] {
    var attributes: [AttributeSyntax] = []
    for element in declaration.attributes {
        guard
            let attribute: AttributeSyntax = element.as(AttributeSyntax.self),
            let identifier: IdentifierTypeSyntax = attribute.attributeName.as(IdentifierTypeSyntax.self),
            verbAttributeNames.contains(identifier.name.text)
        else {
            continue
        }
        attributes.append(attribute)
    }
    return attributes
}

/// Whether `node` is the earliest verb attribute in source order — true for exactly one
/// of several verbs, so the multiple-verb diagnostic is emitted once.
func isEarliestVerb(_ node: AttributeSyntax, among verbs: [AttributeSyntax]) -> Bool {
    let position: AbsolutePosition = node.positionAfterSkippingLeadingTrivia
    return !verbs.contains { verb in
        verb.positionAfterSkippingLeadingTrivia < position
    }
}

/// The non-empty placeholder names in a route template, in order (`"/u/{id}/p/{postId}"`
/// → `["id", "postId"]`). An empty `{}` is not a placeholder and is skipped, mirroring
/// `pathLiteral`'s handling.
func placeholderNames(in template: String) -> [String] {
    var names: [String] = []
    var index: String.Index = template.startIndex

    while index < template.endIndex {
        if template[index] == "{",
           let close: String.Index = template[index...].firstIndex(of: "}") {
            let nameStart: String.Index = template.index(after: index)
            let name: Substring = template[nameStart..<close]
            if !name.isEmpty {
                names.append(String(name))
            }
            index = template.index(after: close)
            continue
        }
        index = template.index(after: index)
    }

    return names
}

/// Finds the marker attribute with the given simple name (`Path`/`Query`/`Body`) on a
/// property declaration, if present.
private func markerAttribute(named name: String, on variable: VariableDeclSyntax) -> AttributeSyntax? {
    for element in variable.attributes {
        guard
            let attribute: AttributeSyntax = element.as(AttributeSyntax.self),
            let identifier: IdentifierTypeSyntax = attribute.attributeName.as(IdentifierTypeSyntax.self),
            identifier.name.text == name
        else {
            continue
        }
        return attribute
    }
    return nil
}

/// Extracts a custom name from a marker attribute's first string-literal argument
/// (e.g. `@Query("page_size")`). Returns `nil` for the bare `@Query`/`@Path` form.
private func customName(from attribute: AttributeSyntax) -> String? {
    guard
        case let .argumentList(arguments) = attribute.arguments,
        let firstArgument = arguments.first,
        let literal = firstArgument.expression.as(StringLiteralExprSyntax.self)
    else {
        return nil
    }
    return literal.representedLiteralValue
}

/// The identifier of a single-binding stored property, if it has one.
private func propertyName(of variable: VariableDeclSyntax) -> String? {
    variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
}

/// The declared type of a single-binding stored property, if annotated.
private func propertyType(of variable: VariableDeclSyntax) -> TypeSyntax? {
    variable.bindings.first?.typeAnnotation?.type
}

/// Classifies a property type as optional and/or array using the sugar syntax forms
/// (`T?`, `[T]`, `[T]?`). The optional wrapper is peeled first so an optional array is
/// reported as both. Generic spellings (`Optional<T>`, `Array<T>`) are out of scope for
/// v1's encoding rules.
///
/// A `nil` type (a property whose type is inferred from its initializer, e.g.
/// `@Query var draft = true`) is treated as a non-optional scalar — the safe default,
/// since the interpolated assignment compiles for any type. Requiring an explicit
/// annotation on marked properties is a possible future refinement, not one of this
/// version's cross-validation scenarios.
private func classify(_ type: TypeSyntax?) -> (isOptional: Bool, isArray: Bool) {
    guard var current: TypeSyntax = type else {
        return (false, false)
    }

    var isOptional: Bool = false
    if let optional = current.as(OptionalTypeSyntax.self) {
        isOptional = true
        current = optional.wrappedType
    } else if let implicitlyUnwrapped = current.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        isOptional = true
        current = implicitlyUnwrapped.wrappedType
    }

    let isArray: Bool = current.is(ArrayTypeSyntax.self)
    return (isOptional, isArray)
}

// MARK: - Member generation

/// Generates `var queryParameters: [String: String]` from the collected `@Query`
/// bindings, or `nil` when there are none (so the protocol default `[:]` is inherited).
///
/// Each binding contributes statements that mutate a local `parameters` dictionary:
/// non-optional scalars assign directly, optionals assign only when non-`nil`, and
/// arrays repeat the key per element (the v1 default). Because the protocol signature
/// is the unchanged `[String: String]`, repeated array keys collapse to the last value
/// at runtime — identical to what a manual struct with the same signature would yield;
/// richer array encoding is a deferred PODRÍA in the design.
func queryParametersDecl(for bindings: [QueryBinding]) -> DeclSyntax? {
    guard !bindings.isEmpty else {
        return nil
    }

    var lines: [String] = ["var parameters: [String: String] = [:]"]
    for binding in bindings {
        lines.append(contentsOf: queryStatementLines(for: binding))
    }
    lines.append("return parameters")

    let body: String = lines.map { "    " + $0 }.joined(separator: "\n")
    let source: String = "var queryParameters: [String: String] {\n\(body)\n}"
    return "\(raw: source)"
}

/// The statements (logical source lines) that emit one `@Query` binding into the
/// `parameters` dictionary, indented relative to the property body's first column.
private func queryStatementLines(for binding: QueryBinding) -> [String] {
    let key: String = quotedLiteral(binding.key)
    let property: String = binding.propertyName

    switch (binding.isOptional, binding.isArray) {
    case (false, false):
        return ["parameters[\(key)] = \"\\(\(property))\""]
    case (true, false):
        return [
            "if let \(property) {",
            "    parameters[\(key)] = \"\\(\(property))\"",
            "}"
        ]
    case (false, true):
        return [
            "for value in \(property) {",
            "    parameters[\(key)] = \"\\(value)\"",
            "}"
        ]
    case (true, true):
        return [
            "if let \(property) {",
            "    for value in \(property) {",
            "        parameters[\(key)] = \"\\(value)\"",
            "    }",
            "}"
        ]
    }
}

/// Generates `var body: (any Encodable & Sendable)?` returning the `@Body` property
/// type-erased, or `nil` when the type has no `@Body` (so the protocol default `nil`
/// is inherited and `body` is not redeclared).
func bodyDecl(for propertyName: String?) -> DeclSyntax? {
    guard let propertyName else {
        return nil
    }
    let source: String = "var body: (any Encodable & Sendable)? {\n    \(propertyName)\n}"
    return "\(raw: source)"
}

/// Renders a string as the *source text* of a Swift string literal, escaping the
/// characters that would otherwise break it. Used for query keys spliced via `\(raw:)`.
private func quotedLiteral(_ value: String) -> String {
    var result: String = "\""
    for character in value {
        switch character {
        case "\\": result += "\\\\"
        case "\"": result += "\\\""
        default: result.append(character)
        }
    }
    result += "\""
    return result
}
