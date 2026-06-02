import SwiftDiagnostics
import SwiftSyntax

// MARK: - Diagnostic messages

/// A diagnostic emitted by a verb macro during expansion. The verb macro cross-checks
/// the route template against the type's `@Path`/`@Body` markers and reports a specific,
/// node-anchored message (via the macro context) instead of a generic macro failure.
struct VerbDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(_ message: String, id: String, severity: DiagnosticSeverity = .error) {
        self.message = message
        self.diagnosticID = MessageID(domain: "NetKitMacros", id: id)
        self.severity = severity
    }
}

/// The message shown on a FixIt offered alongside a `VerbDiagnostic`.
struct VerbFixItMessage: FixItMessage {
    let message: String
    let fixItID: MessageID

    init(_ message: String, id: String) {
        self.message = message
        self.fixItID = MessageID(domain: "NetKitMacros", id: id)
    }
}

// MARK: - Diagnostic builders

/// Builds the diagnostics for the route↔`@Path` mismatches: a `{placeholder}` in the
/// template with no matching `@Path` property (anchored to the route annotation) and a
/// `@Path` property with no matching placeholder (anchored to the property, with a FixIt
/// that removes the stray `@Path`).
func routeMismatchDiagnostics(
    template: String,
    pathProperties: [PathProperty],
    route: AttributeSyntax
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []

    let placeholders: [String] = placeholderNames(in: template)
    let placeholderSet: Set<String> = Set(placeholders)
    let coveredKeys: Set<String> = Set(pathProperties.map(\.key))

    // Each uncovered placeholder is anchored to the route annotation — the literal is
    // what names the placeholder, so that is where the developer fixes it.
    for name in placeholders where !coveredKeys.contains(name) {
        diagnostics.append(
            Diagnostic(
                node: route,
                message: VerbDiagnostic(
                    "Route placeholder '{\(name)}' has no matching '@Path' property",
                    id: "uncoveredPlaceholder"
                )
            )
        )
    }

    // Each orphan `@Path` is anchored to its property; removing the marker is the single
    // clear correction (the property stays valid), so it is offered as a FixIt.
    for property in pathProperties where !placeholderSet.contains(property.key) {
        let fixIt: FixIt = FixIt(
            message: VerbFixItMessage("Remove '@Path' from '\(property.name)'", id: "removePath"),
            changes: [removeAttributeChange(property.attribute, from: property.variable)]
        )
        let message: String = "'@Path' property '\(property.name)' has no matching "
            + "'{\(property.key)}' placeholder in the route template"
        diagnostics.append(
            Diagnostic(
                node: Syntax(property.variable),
                message: VerbDiagnostic(message, id: "orphanPath"),
                fixIts: [fixIt]
            )
        )
    }

    return diagnostics
}

/// Builds the diagnostic for a `@Body` declared under a verb that takes no request body
/// (e.g. `GET`). It is anchored to the verb annotation — the verb is what makes the body
/// invalid — and offers a FixIt that removes the stray `@Body`.
func bodyNotAllowedDiagnostic(
    verb: String,
    body: BodyProperty,
    route: AttributeSyntax
) -> Diagnostic {
    let fixIt: FixIt = FixIt(
        message: VerbFixItMessage("Remove '@Body' from '\(body.name)'", id: "removeBody"),
        changes: [removeAttributeChange(body.attribute, from: body.variable)]
    )
    return Diagnostic(
        node: route,
        message: VerbDiagnostic(
            "\(verb.uppercased()) requests take no body; remove '@Body' or use POST, PUT, or PATCH",
            id: "bodyNotAllowed"
        ),
        fixIts: [fixIt]
    )
}

/// Builds the diagnostic for more than one HTTP verb applied to the same type, anchored
/// to the offending verb annotation.
func multipleVerbsDiagnostic(at route: AttributeSyntax) -> Diagnostic {
    Diagnostic(
        node: route,
        message: VerbDiagnostic(
            "A type may declare only one HTTP verb macro; remove the extra verb annotation",
            id: "multipleVerbs"
        )
    )
}

// MARK: - FixIt construction

/// A `FixIt.Change` that removes `attribute` from `variable`'s attribute list, preserving
/// the declaration's original leading trivia so the surviving `var` keeps its indentation.
private func removeAttributeChange(
    _ attribute: AttributeSyntax,
    from variable: VariableDeclSyntax
) -> FixIt.Change {
    let remaining: AttributeListSyntax = variable.attributes.filter { element in
        element.as(AttributeSyntax.self) != attribute
    }
    let updated: VariableDeclSyntax = variable
        .with(\.attributes, remaining)
        .with(\.leadingTrivia, variable.leadingTrivia)
    return FixIt.Change.replace(oldNode: Syntax(variable), newNode: Syntax(updated))
}
