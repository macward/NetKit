import Foundation

/// An in-memory cache for storing API responses with TTL support.
public actor ResponseCache {
    /// A cached entry with expiration time.
    private struct CacheEntry {
        let data: Data
        let expiresAt: Date

        var isExpired: Bool {
            Date() > expiresAt
        }
    }

    private var storage: [String: CacheEntry] = [:]
    private let maxEntries: Int?

    /// Creates a response cache.
    /// - Parameter maxEntries: Optional maximum number of entries. When exceeded, oldest entries are removed.
    public init(maxEntries: Int? = nil) {
        self.maxEntries = maxEntries
    }

    /// Stores data in the cache.
    /// - Parameters:
    ///   - data: The data to cache.
    ///   - request: The request to use as the cache key.
    ///   - ttl: Time-to-live in seconds.
    public func store(data: Data, for request: URLRequest, ttl: TimeInterval) {
        let key = cacheKey(for: request)
        let entry = CacheEntry(data: data, expiresAt: Date().addingTimeInterval(ttl))
        storage[key] = entry

        enforceMaxEntries()
    }

    /// Retrieves cached data for a request.
    /// - Parameter request: The request to look up.
    /// - Returns: The cached data, or nil if not found or expired.
    public func retrieve(for request: URLRequest) -> Data? {
        let key = cacheKey(for: request)
        guard let entry = storage[key] else { return nil }

        if entry.isExpired {
            storage.removeValue(forKey: key)
            return nil
        }

        return entry.data
    }

    /// Invalidates the cache entry for a specific request.
    /// - Parameter request: The request whose cache entry should be removed.
    public func invalidate(for request: URLRequest) {
        let key = cacheKey(for: request)
        storage.removeValue(forKey: key)
    }

    /// Invalidates all cached entries.
    public func invalidateAll() {
        storage.removeAll()
    }

    /// Removes all expired entries from the cache.
    public func pruneExpired() {
        storage = storage.filter { !$0.value.isExpired }
    }

    /// The current number of cached entries.
    public var count: Int {
        storage.count
    }

    /// Generates a cache key from a URLRequest.
    /// - Parameter request: The request.
    /// - Returns: A unique string key based on method, URL, and relevant headers.
    private func cacheKey(for request: URLRequest) -> String {
        var components: [String] = []

        // Method
        components.append(request.httpMethod ?? "GET")

        // Full URL including query parameters
        if let url = request.url?.absoluteString {
            components.append(url)
        }

        // Include specific headers that might affect the response
        let relevantHeaders = ["Accept", "Accept-Language", "Accept-Encoding"]
        for header in relevantHeaders {
            if let value = request.value(forHTTPHeaderField: header) {
                components.append("\(header):\(value)")
            }
        }

        return components.joined(separator: "|")
    }

    /// Enforces the maximum entries limit by removing oldest entries.
    private func enforceMaxEntries() {
        guard let max = maxEntries, storage.count > max else { return }

        // Remove expired entries first
        pruneExpired()

        // If still over limit, remove oldest entries
        while storage.count > max {
            // Find the entry that expires soonest (approximation of oldest)
            if let oldestKey = storage.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                storage.removeValue(forKey: oldestKey)
            } else {
                break
            }
        }
    }
}
