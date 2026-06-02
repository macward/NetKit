import Foundation

// MARK: - Query Key

/// A stable, content-derived identity for a resource in the data layer.
///
/// Two endpoint values that address the *same* server resource (same method, path,
/// query, body) **and** decode to the same `Response` type produce the same key, so
/// they share a single ``QueryEntry`` in the store. The `Response` type is part of the
/// key on purpose: two endpoints with an identical URL but different response types are
/// distinct resources and must not collide.
///
/// ## Auth isolation
///
/// A resource decoded under one session must never be served to another (R12). The key
/// therefore folds in an *auth context* — a stable identifier for the active session —
/// mirroring how ``CacheKeyGenerator`` includes the `Authorization` header so cached
/// bytes are not shared across auth contexts. The ``QueryClient`` resolves the active
/// session and is the single place that builds keys with it (see `QueryClient.key(for:)`);
/// callers should not construct auth-scoped keys by hand.
///
/// - Note: Keying assumes the endpoint is deterministic. Endpoints whose `body`,
///   `queryParameters`, or `path` vary across evaluations (e.g. closures, timestamps)
///   will not key stably — that is a documented contract of the data layer.
public struct QueryKey: Hashable, Sendable {
    /// The content-derived identity string. Exposed for debugging and logging only —
    /// its exact format is an implementation detail and is **not** stable across library
    /// versions; do not parse or persist it.
    public let raw: String

    /// Derives a key from an endpoint with no auth scoping. Two sessions would collide on
    /// this key; prefer `QueryClient.key(for:)`, which folds in the active auth context.
    public init<E: Endpoint>(_ endpoint: E) {
        self.init(endpoint, authContext: nil)
    }

    /// Derives a key from an endpoint, scoped to an auth context.
    ///
    /// - Parameter authContext: A stable identifier for the active session (e.g. a user
    ///   id or a token fingerprint). When non-`nil` and non-empty, two distinct sessions
    ///   produce distinct keys for the same endpoint, isolating their decoded values
    ///   (R12). Pass `nil` for unauthenticated resources or when no session is active.
    public init<E: Endpoint>(_ endpoint: E, authContext: String?) {
        var parts: [String] = [endpoint.method.rawValue, endpoint.path]

        // Query parameters, order-independent.
        let sortedQuery: [(String, String)] = endpoint.queryParameters.sorted { $0.key < $1.key }
        parts.append(contentsOf: sortedQuery.map { "\($0.0)=\($0.1)" })

        // The decoded type is part of the identity.
        parts.append("→\(String(reflecting: E.Response.self))")

        // Best-effort body fingerprint (relevant for non-GET resources).
        if let body = endpoint.body,
           let data: Data = try? JSONEncoder().encode(BodyFingerprint(body)) {
            parts.append("body:\(data.count):\(data.hashValue)")
        }

        // Auth context, so a value cached under one session is invisible to another (R12).
        if let authContext, !authContext.isEmpty {
            parts.append("auth:\(authContext)")
        }

        self.raw = parts.joined(separator: "|")
    }
}

// MARK: - Body Fingerprint

/// Type-erased `Encodable` used only to fingerprint a request body for keying.
private struct BodyFingerprint: Encodable {
    private let encodeBody: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeBody = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}
