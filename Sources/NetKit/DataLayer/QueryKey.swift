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
/// - Note: Keying assumes the endpoint is deterministic. Endpoints whose `body`,
///   `queryParameters`, or `path` vary across evaluations (e.g. closures, timestamps)
///   will not key stably — that is a documented contract of the data layer.
public struct QueryKey: Hashable, Sendable {
    public let raw: String

    public init<E: Endpoint>(_ endpoint: E) {
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
