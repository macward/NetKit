import Foundation

/// An in-memory cache for storing API responses with HTTP cache header support.
public actor ResponseCache {
    /// Default maximum entries when not specified. Set to prevent unbounded memory growth.
    public static let defaultMaxEntries: Int = 100

    /// A cached entry with data, metadata, and expiration support.
    private struct CacheEntry {
        let data: Data
        let metadata: CacheMetadata

        /// Expiration time derived from metadata for single source of truth.
        var expiresAt: Date {
            metadata.expiresAt ?? Date.distantFuture
        }

        var isExpired: Bool {
            metadata.isExpired
        }

        /// Checks if stale content can be served within a window.
        func canServeStale(within window: TimeInterval) -> Bool {
            metadata.isStaleButRevalidatable(within: window)
        }
    }

    private var storage: [String: CacheEntry] = [:]
    private let maxEntries: Int?
    private let cachePolicy: CachePolicy

    /// Creates a response cache.
    /// - Parameters:
    ///   - maxEntries: Optional maximum number of entries. When exceeded, oldest entries are removed.
    ///   - cachePolicy: The cache policy to use. Defaults to HTTPCachePolicy with no default TTL.
    public init(maxEntries: Int? = nil, cachePolicy: CachePolicy = HTTPCachePolicy()) {
        self.maxEntries = maxEntries
        self.cachePolicy = cachePolicy
    }

    // MARK: - Public API

    /// Stores data in the cache based on HTTP response headers.
    /// - Parameters:
    ///   - data: The data to cache.
    ///   - request: The request to use as the cache key.
    ///   - response: The HTTP response containing cache headers.
    /// - Returns: True if the data was cached, false if caching was not allowed.
    @discardableResult
    public func store(data: Data, for request: URLRequest, response: HTTPURLResponse) -> Bool {
        guard cachePolicy.shouldCache(response: response) else {
            return false
        }

        guard let ttl = cachePolicy.ttl(for: response), ttl > 0 else {
            return false
        }

        let metadata: CacheMetadata = CacheMetadataFactory.create(from: response, policy: cachePolicy)
        let entry: CacheEntry = CacheEntry(data: data, metadata: metadata)

        let key: String = cacheKey(for: request)
        storage[key] = entry
        enforceMaxEntries()
        return true
    }

    /// Stores data in the cache with explicit TTL (legacy support).
    /// - Parameters:
    ///   - data: The data to cache.
    ///   - request: The request to use as the cache key.
    ///   - ttl: Time-to-live in seconds.
    public func store(data: Data, for request: URLRequest, ttl: TimeInterval) {
        let key: String = cacheKey(for: request)
        let metadata: CacheMetadata = CacheMetadata(
            cachedAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )
        let entry: CacheEntry = CacheEntry(data: data, metadata: metadata)
        storage[key] = entry
        enforceMaxEntries()
    }

    /// Retrieves cached data for a request.
    /// - Parameter request: The request to look up.
    /// - Returns: The cached data, or nil if not found or expired.
    public func retrieve(for request: URLRequest) -> Data? {
        let result: CacheRetrievalResult = retrieveWithMetadata(for: request)
        switch result {
        case .fresh(let data, _):
            return data
        case .stale, .needsRevalidation, .miss:
            return nil
        }
    }

    /// Retrieves cached data with full metadata for conditional request support.
    /// - Parameter request: The request to look up.
    /// - Returns: A result indicating the cache state and data.
    public func retrieveWithMetadata(for request: URLRequest) -> CacheRetrievalResult {
        let key: String = cacheKey(for: request)
        guard let entry = storage[key] else {
            return .miss
        }

        let staleWindow: TimeInterval = entry.metadata.cacheControl?.staleWhileRevalidate ?? 0

        if !entry.isExpired {
            if entry.metadata.requiresRevalidation {
                return .needsRevalidation(entry.data, entry.metadata)
            }
            return .fresh(entry.data, entry.metadata)
        }

        if entry.canServeStale(within: staleWindow) {
            return .stale(entry.data, entry.metadata)
        }

        if entry.metadata.etag != nil || entry.metadata.lastModified != nil {
            return .needsRevalidation(entry.data, entry.metadata)
        }

        storage.removeValue(forKey: key)
        return .miss
    }

    /// Updates cache entry after a 304 Not Modified response.
    /// - Parameters:
    ///   - request: The request used as cache key.
    ///   - response: The 304 response with potentially updated headers.
    public func updateAfterRevalidation(for request: URLRequest, response: HTTPURLResponse) {
        let key: String = cacheKey(for: request)
        guard let existingEntry = storage[key] else { return }

        let newMetadata: CacheMetadata = CacheMetadataFactory.create(from: response, policy: cachePolicy)
        let ttl: TimeInterval = cachePolicy.ttl(for: response) ?? 0
        let updatedMetadata: CacheMetadata = CacheMetadata(
            etag: newMetadata.etag ?? existingEntry.metadata.etag,
            lastModified: newMetadata.lastModified ?? existingEntry.metadata.lastModified,
            cachedAt: Date(),
            expiresAt: ttl > 0 ? Date().addingTimeInterval(ttl) : existingEntry.metadata.expiresAt,
            cacheControl: newMetadata.cacheControl ?? existingEntry.metadata.cacheControl
        )
        let newEntry: CacheEntry = CacheEntry(data: existingEntry.data, metadata: updatedMetadata)
        storage[key] = newEntry
    }

    /// Retrieves metadata for a request without returning data.
    /// Useful for adding conditional headers to requests.
    /// - Parameter request: The request to look up.
    /// - Returns: The cache metadata, or nil if not cached.
    public func metadata(for request: URLRequest) -> CacheMetadata? {
        let key: String = cacheKey(for: request)
        return storage[key]?.metadata
    }

    /// Invalidates the cache entry for a specific request.
    /// - Parameter request: The request whose cache entry should be removed.
    public func invalidate(for request: URLRequest) {
        let key: String = cacheKey(for: request)
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

    // MARK: - Private

    /// Generates a cache key from a URLRequest.
    private func cacheKey(for request: URLRequest) -> String {
        var components: [String] = []

        components.append(request.httpMethod ?? "GET")

        if let url = request.url?.absoluteString {
            components.append(url)
        }

        let relevantHeaders: [String] = ["Accept", "Accept-Language", "Accept-Encoding"]
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

        pruneExpired()

        while storage.count > max {
            if let oldestKey = storage.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                storage.removeValue(forKey: oldestKey)
            } else {
                break
            }
        }
    }
}

// MARK: - Cache Retrieval Result

/// The result of a cache lookup with metadata.
public enum CacheRetrievalResult: Sendable {
    /// Fresh data that can be used immediately.
    case fresh(Data, CacheMetadata)

    /// Stale data that can be served while revalidating in background.
    case stale(Data, CacheMetadata)

    /// Data exists but requires revalidation before use.
    case needsRevalidation(Data, CacheMetadata)

    /// No cached data available.
    case miss

    /// Returns the cached data if available.
    public var data: Data? {
        switch self {
        case .fresh(let data, _), .stale(let data, _), .needsRevalidation(let data, _):
            return data
        case .miss:
            return nil
        }
    }

    /// Returns the metadata if available.
    public var metadata: CacheMetadata? {
        switch self {
        case .fresh(_, let metadata), .stale(_, let metadata), .needsRevalidation(_, let metadata):
            return metadata
        case .miss:
            return nil
        }
    }

    /// Whether the result represents fresh, immediately usable data.
    public var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }

    /// Whether the result represents stale data that can be served while revalidating.
    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    /// Whether the cached data requires revalidation before use.
    public var requiresRevalidation: Bool {
        if case .needsRevalidation = self { return true }
        return false
    }

    /// Whether no cached data was found.
    public var isMiss: Bool {
        if case .miss = self { return true }
        return false
    }
}
