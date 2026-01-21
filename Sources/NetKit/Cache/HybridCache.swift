import Foundation

/// A hybrid cache that uses memory as L1 cache and disk as L2 cache.
/// Hot data stays in memory for fast access, all data is persisted to disk.
public actor HybridCache {
    // MARK: - Properties

    private let memoryCache: ResponseCache
    private let diskCache: DiskCache
    private let cachePolicy: CachePolicy

    // MARK: - Initialization

    /// Creates a hybrid cache with memory and disk layers.
    /// - Parameters:
    ///   - memoryMaxEntries: Maximum entries in memory cache.
    ///   - diskConfiguration: Configuration for disk cache.
    ///   - cachePolicy: The cache policy to use.
    /// - Throws: An error if the disk cache cannot be initialized.
    public init(
        memoryMaxEntries: Int = ResponseCache.defaultMaxEntries,
        diskConfiguration: DiskCacheConfiguration = .default,
        cachePolicy: CachePolicy = HTTPCachePolicy()
    ) throws {
        self.cachePolicy = cachePolicy
        self.memoryCache = ResponseCache(maxEntries: memoryMaxEntries, cachePolicy: cachePolicy)
        self.diskCache = try DiskCache(configuration: diskConfiguration, cachePolicy: cachePolicy)
    }

    /// Initializes the cache. Must be called after creation.
    public func setup() async throws {
        try await diskCache.setup()
    }

    // MARK: - Public API

    /// Stores data in both memory and disk cache based on HTTP response headers.
    /// - Parameters:
    ///   - data: The data to cache.
    ///   - request: The request to use as the cache key.
    ///   - response: The HTTP response containing cache headers.
    /// - Returns: True if the data was cached, false if caching was not allowed.
    @discardableResult
    public func store(data: Data, for request: URLRequest, response: HTTPURLResponse) async -> Bool {
        // Store in memory first (fast path)
        let memoryCached: Bool = await memoryCache.store(data: data, for: request, response: response)

        // Store in disk (persistence)
        let diskCached: Bool = await diskCache.store(data: data, for: request, response: response)

        return memoryCached || diskCached
    }

    /// Stores data in both caches with explicit TTL.
    /// - Parameters:
    ///   - data: The data to cache.
    ///   - request: The request to use as the cache key.
    ///   - ttl: Time-to-live in seconds.
    /// - Returns: True if stored successfully.
    @discardableResult
    public func store(data: Data, for request: URLRequest, ttl: TimeInterval) async -> Bool {
        // Store in memory
        await memoryCache.store(data: data, for: request, ttl: ttl)

        // Store in disk
        let diskCached: Bool = await diskCache.store(data: data, for: request, ttl: ttl)

        return diskCached
    }

    /// Retrieves cached data for a request.
    /// Checks memory first, falls back to disk.
    /// - Parameter request: The request to look up.
    /// - Returns: The cached data, or nil if not found or expired.
    public func retrieve(for request: URLRequest) async -> Data? {
        let result: CacheRetrievalResult = await retrieveWithMetadata(for: request)
        switch result {
        case .fresh(let data, _):
            return data
        case .stale, .needsRevalidation, .miss:
            return nil
        }
    }

    /// Retrieves cached data with full metadata for conditional request support.
    /// Checks memory first, falls back to disk, promotes disk hits to memory.
    /// - Parameter request: The request to look up.
    /// - Returns: A result indicating the cache state and data.
    public func retrieveWithMetadata(for request: URLRequest) async -> CacheRetrievalResult {
        // Try memory first (L1)
        let memoryResult: CacheRetrievalResult = await memoryCache.retrieveWithMetadata(for: request)
        if !memoryResult.isMiss {
            return memoryResult
        }

        // Fall back to disk (L2)
        let diskResult: CacheRetrievalResult = await diskCache.retrieveWithMetadata(for: request)

        // Promote disk hit to memory for future fast access
        if let data = diskResult.data, let metadata = diskResult.metadata {
            await promoteToMemory(data: data, for: request, metadata: metadata)
        }

        return diskResult
    }

    /// Updates cache entry after a 304 Not Modified response.
    /// - Parameters:
    ///   - request: The request used as cache key.
    ///   - response: The 304 response with potentially updated headers.
    public func updateAfterRevalidation(for request: URLRequest, response: HTTPURLResponse) async {
        await memoryCache.updateAfterRevalidation(for: request, response: response)
        await diskCache.updateAfterRevalidation(for: request, response: response)
    }

    /// Retrieves metadata for a request without loading data.
    /// - Parameter request: The request to look up.
    /// - Returns: The cache metadata, or nil if not cached.
    public func metadata(for request: URLRequest) async -> CacheMetadata? {
        // Try memory first
        if let memoryMetadata = await memoryCache.metadata(for: request) {
            return memoryMetadata
        }
        // Fall back to disk
        return await diskCache.metadata(for: request)
    }

    /// Invalidates the cache entry for a specific request in both caches.
    /// - Parameter request: The request whose cache entry should be removed.
    public func invalidate(for request: URLRequest) async {
        await memoryCache.invalidate(for: request)
        await diskCache.invalidate(for: request)
    }

    /// Invalidates all cached entries in both caches.
    public func invalidateAll() async {
        await memoryCache.invalidateAll()
        await diskCache.invalidateAll()
    }

    /// Removes all expired entries from both caches.
    public func pruneExpired() async {
        await memoryCache.pruneExpired()
        await diskCache.pruneExpired()
    }

    /// Removes entries older than the specified age from disk cache.
    /// - Parameter maxAge: Maximum age in seconds.
    public func pruneOlderThan(_ maxAge: TimeInterval) async {
        await diskCache.pruneOlderThan(maxAge)
    }

    /// Invalidates entries matching a URL pattern.
    /// - Parameter pattern: A string pattern to match against cache keys.
    public func invalidateMatching(pattern: String) async {
        await diskCache.invalidateMatching(pattern: pattern)
        // Memory cache doesn't expose pattern-based invalidation,
        // so we invalidate all memory to ensure consistency
        await memoryCache.invalidateAll()
    }

    /// The current number of entries in memory cache.
    public var memoryCount: Int {
        get async {
            await memoryCache.count
        }
    }

    /// The current number of entries in disk cache.
    public var diskCount: Int {
        get async {
            await diskCache.count
        }
    }

    /// The current total size of disk cache in bytes.
    public var diskSize: Int {
        get async {
            await diskCache.totalSize
        }
    }

    // MARK: - Private Methods

    private func promoteToMemory(data: Data, for request: URLRequest, metadata: CacheMetadata) async {
        // Only promote if not expired
        guard !metadata.isExpired else { return }

        if let ttl = metadata.expiresAt?.timeIntervalSinceNow, ttl > 0 {
            await memoryCache.store(data: data, for: request, ttl: ttl)
        }
    }
}
