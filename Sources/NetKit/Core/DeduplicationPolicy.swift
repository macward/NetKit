import Foundation

/// Controls whether identical concurrent requests should be deduplicated.
///
/// Request deduplication prevents multiple identical network calls from executing
/// simultaneously by reusing the result of the first in-flight request for all callers.
///
/// Example:
/// ```swift
/// struct UserEndpoint: Endpoint {
///     var deduplicationPolicy: DeduplicationPolicy { .automatic }
/// }
///
/// // With .automatic, 10 concurrent GET requests will only execute 1 real network call
/// ```
public enum DeduplicationPolicy: Sendable {
    /// Automatically deduplicate GET requests; mutations (POST, PUT, PATCH, DELETE) are never deduplicated.
    /// This is the default and recommended setting for most endpoints.
    case automatic

    /// Always deduplicate identical concurrent requests, including mutations.
    /// Use this for idempotent POST endpoints or other special cases.
    case always

    /// Never deduplicate requests for this endpoint.
    /// Use this for GET endpoints with side effects or when each request must execute independently.
    case never
}
