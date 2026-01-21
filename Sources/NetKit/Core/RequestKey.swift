import Foundation

/// A hashable key that uniquely identifies a network request for deduplication purposes.
///
/// Two requests are considered identical if they have the same URL, HTTP method, and body content.
/// Headers are intentionally excluded to keep the implementation simple and avoid edge cases
/// with transient headers like request IDs or timestamps.
///
/// - Note: The body hash uses Swift's built-in hashValue which is consistent within a process
///   but may vary between runs. This is acceptable for in-memory deduplication.
internal struct RequestKey: Hashable, Sendable {
    let url: URL
    let method: String
    let bodyHash: Int?

    /// Creates a request key from a URLRequest.
    ///
    /// - Parameter request: The URLRequest to create a key from.
    /// - Precondition: The request must have a valid URL. If the URL is nil, this initializer
    ///   will use a placeholder URL which may cause unexpected deduplication behavior.
    init(from request: URLRequest) {
        // URLRequest should always have a URL at this point in NetworkClient flow,
        // but we provide a safe fallback to avoid crashes.
        self.url = request.url ?? URL(string: "about:invalid")!
        self.method = request.httpMethod ?? "GET"
        self.bodyHash = request.httpBody?.hashValue
    }
}
