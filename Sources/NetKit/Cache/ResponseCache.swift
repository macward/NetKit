import Foundation

/// An in-memory cache for storing API responses with HTTP cache header support.
public actor ResponseCache {
    /// Default maximum entries when not specified. Set to prevent unbounded memory growth.
    public static let defaultMaxEntries: Int = 100

    /// A cached entry with data, metadata, and LRU tracking.
    private struct CacheEntry {
        let data: Data
        let metadata: CacheMetadata

        /// When this entry was last accessed (for LRU eviction).
        var lastAccessedAt: Date

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

        init(data: Data, metadata: CacheMetadata, lastAccessedAt: Date = Date()) {
            self.data = data
            self.metadata = metadata
            self.lastAccessedAt = lastAccessedAt
        }
    }

    private var storage: [String: CacheEntry] = [:]
    private let maxEntries: Int?
    private let cachePolicy: CachePolicy

    /// Creates a response cache.
    /// - Parameters:
    ///   - maxEntries: Maximum number of entries. Defaults to `defaultMaxEntries` (100).
    ///     When exceeded, least recently used entries are evicted.
    ///   - cachePolicy: The cache policy to use. Defaults to HTTPCachePolicy with no default TTL.
    public init(maxEntries: Int? = defaultMaxEntries, cachePolicy: CachePolicy = HTTPCachePolicy()) {
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
        guard var entry = storage[key] else {
            return .miss
        }

        let staleWindow: TimeInterval = entry.metadata.cacheControl?.staleWhileRevalidate ?? 0

        if !entry.isExpired {
            // Update last access time for LRU tracking
            entry.lastAccessedAt = Date()
            storage[key] = entry

            if entry.metadata.requiresRevalidation {
                return .needsRevalidation(entry.data, entry.metadata)
            }
            return .fresh(entry.data, entry.metadata)
        }

        if entry.canServeStale(within: staleWindow) {
            // Update last access time even for stale data
            entry.lastAccessedAt = Date()
            storage[key] = entry
            return .stale(entry.data, entry.metadata)
        }

        if entry.metadata.etag != nil || entry.metadata.lastModified != nil {
            // Update last access time for revalidation candidates
            entry.lastAccessedAt = Date()
            storage[key] = entry
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

    /// Invalidates entries matching a URL pattern.
    ///
    /// Uses simple string containment matching against cache keys.
    /// Cache keys include the HTTP method and URL, so patterns like
    /// "/users" will match all cached requests containing that path.
    ///
    /// - Parameter pattern: A string pattern to match against cache keys.
    public func invalidateMatching(pattern: String) {
        let matchingKeys: [String] = storage.keys.filter { $0.contains(pattern) }
        for key in matchingKeys {
            storage.removeValue(forKey: key)
        }
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
        CacheKeyGenerator.cacheKey(for: request)
    }

    /// Enforces the maximum entries limit using LRU (Least Recently Used) eviction.
    ///
    /// First prunes expired entries, then evicts the least recently accessed
    /// entries until the cache is within the limit. This ensures hot entries
    /// are kept even if they have shorter TTLs.
    private func enforceMaxEntries() {
        guard let max = maxEntries, storage.count > max else { return }

        // First, remove expired entries (they're definitely not needed)
        pruneExpired()

        // If still over limit, evict least recently used entries
        while storage.count > max {
            if let lruKey = storage.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })?.key {
                storage.removeValue(forKey: lruKey)
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
