import NetKit

// Public macro declarations for NetKit. The implementations live in the
// `NetKitMacrosImpl` compiler plugin — the only target that depends on swift-syntax.

// MARK: - HTTP verb macros

/// Declares the annotated type as a `GET` endpoint for the given path template.
///
/// Generates the `Endpoint` conformance plus `path`, `method`, `queryParameters`
/// and `body` from the type's `@Path`/`@Query`/`@Body` properties.
@attached(member, names: named(path), named(method), named(queryParameters), named(body))
@attached(extension, conformances: Endpoint)
public macro GET(_ path: String) = #externalMacro(module: "NetKitMacrosImpl", type: "GETMacro")

/// Declares the annotated type as a `POST` endpoint for the given path template.
@attached(member, names: named(path), named(method), named(queryParameters), named(body))
@attached(extension, conformances: Endpoint)
public macro POST(_ path: String) = #externalMacro(module: "NetKitMacrosImpl", type: "POSTMacro")

/// Declares the annotated type as a `PUT` endpoint for the given path template.
@attached(member, names: named(path), named(method), named(queryParameters), named(body))
@attached(extension, conformances: Endpoint)
public macro PUT(_ path: String) = #externalMacro(module: "NetKitMacrosImpl", type: "PUTMacro")

/// Declares the annotated type as a `PATCH` endpoint for the given path template.
@attached(member, names: named(path), named(method), named(queryParameters), named(body))
@attached(extension, conformances: Endpoint)
public macro PATCH(_ path: String) = #externalMacro(module: "NetKitMacrosImpl", type: "PATCHMacro")

/// Declares the annotated type as a `DELETE` endpoint for the given path template.
@attached(member, names: named(path), named(method), named(queryParameters), named(body))
@attached(extension, conformances: Endpoint)
public macro DELETE(_ path: String) = #externalMacro(module: "NetKitMacrosImpl", type: "DELETEMacro")

// MARK: - Property markers

/// Marks a stored property whose value substitutes the matching `{placeholder}` in
/// the endpoint's path template at runtime.
@attached(peer)
public macro Path() = #externalMacro(module: "NetKitMacrosImpl", type: "PathMacro")

/// Marks a stored property that is appended to the endpoint's `queryParameters`.
@attached(peer)
public macro Query() = #externalMacro(module: "NetKitMacrosImpl", type: "QueryMacro")

/// Marks the stored property used as the endpoint's request `body`.
@attached(peer)
public macro Body() = #externalMacro(module: "NetKitMacrosImpl", type: "BodyMacro")
