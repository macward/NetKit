import Foundation

/// A disk-based cache actor that persists cached responses to the file system.
/// Uses FileManager for file operations, isolated within the actor for thread safety.
public actor DiskCache {
    // MARK: - Properties

    private let fileManager: FileManager = .default
    private let configuration: DiskCacheConfiguration
    private let cachePolicy: CachePolicy
    private var index: DiskCacheIndex
    private let cacheDirectory: URL
    private let entriesDirectory: URL
    private let indexFileURL: URL
    private let versionFileURL: URL

    // MARK: - Index Writer (Serialized Writes with Coalescing)

    private let indexWriter: IndexWriter

    // MARK: - Initialization

    /// Creates a disk cache with the specified configuration.
    /// - Parameters:
    ///   - configuration: The disk cache configuration.
    ///   - cachePolicy: The cache policy to use. Defaults to HTTPCachePolicy.
    /// - Throws: An error if the cache directory cannot be created.
    public init(
        configuration: DiskCacheConfiguration = .default,
        cachePolicy: CachePolicy = HTTPCachePolicy()
    ) throws {
        self.configuration = configuration
        self.cachePolicy = cachePolicy

        guard let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw DiskCacheError.directoryNotFound
        }

        self.cacheDirectory = cachesDirectory.appendingPathComponent(configuration.directoryName)
        self.entriesDirectory = cacheDirectory.appendingPathComponent("entries")
        self.indexFileURL = cacheDirectory.appendingPathComponent("index.json")
        self.versionFileURL = cacheDirectory.appendingPathComponent("version")

        // Load or create index
        self.index = DiskCacheIndex()

        // Initialize the serialized index writer
        self.indexWriter = IndexWriter(
            indexURL: indexFileURL,
            cacheDirectory: cacheDirectory
        )

        // Setup will be called after init completes
    }

    /// Initializes the cache directory structure and loads the index.
    /// Must be called after initialization when using init() directly.
    /// Prefer using the static `create()` factory method instead.
    public func setup() async throws {
        try createDirectoryStructure()
        try await loadOrMigrateIndex()
    }

    /// Creates and initializes a disk cache in one step.
    /// This is the preferred way to create a DiskCache instance.
    /// - Parameters:
    ///   - configuration: The disk cache configuration.
    ///   - cachePolicy: The cache policy to use. Defaults to HTTPCachePolicy.
    /// - Returns: A fully initialized DiskCache ready to use.
    /// - Throws: An error if initialization fails.
    public static func create(
        configuration: DiskCacheConfiguration = .default,
        cachePolicy: CachePolicy = HTTPCachePolicy()
    ) async throws -> DiskCache {
        let cache: DiskCache = try DiskCache(configuration: configuration, cachePolicy: cachePolicy)
        try await cache.setup()
        return cache
    }

    // MARK: - Public API

    /// Stores data in the disk cache based on HTTP response headers.
    /// - Parameters:
    ///   - data: The data to cache.
    ///   - request: The request to use as the cache key.
    ///   - response: The HTTP response containing cache headers.
    /// - Returns: True if the data was cached, false if caching was not allowed.
    @discardableResult
    public func store(data: Data, for request: URLRequest, response: HTTPURLResponse) async -> Bool {
        guard cachePolicy.shouldCache(response: response) else {
            return false
        }

        guard let ttl = cachePolicy.ttl(for: response), ttl > 0 else {
            return false
        }

        guard data.count <= configuration.maxEntrySize else {
            return false
        }

        let metadata: CacheMetadata = CacheMetadataFactory.create(from: response, policy: cachePolicy)
        return await store(data: data, for: request, metadata: metadata)
    }

    /// Stores data in the disk cache with explicit TTL.
    /// - Parameters:
    ///   - data: The data to cache.
    ///   - request: The request to use as the cache key.
    ///   - ttl: Time-to-live in seconds.
    /// - Returns: True if stored successfully.
    @discardableResult
    public func store(data: Data, for request: URLRequest, ttl: TimeInterval) async -> Bool {
        guard data.count <= configuration.maxEntrySize else {
            return false
        }

        let metadata: CacheMetadata = CacheMetadata(
            cachedAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )
        return await store(data: data, for: request, metadata: metadata)
    }

    /// Retrieves cached data for a request.
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
    /// - Parameter request: The request to look up.
    /// - Returns: A result indicating the cache state and data.
    public func retrieveWithMetadata(for request: URLRequest) async -> CacheRetrievalResult {
        let key: String = CacheKeyGenerator.cacheKey(for: request)
        guard var entry = index.entries[key] else {
            return .miss
        }

        // Update last accessed time for LRU
        entry.lastAccessedAt = Date()
        index.entries[key] = entry

        // Load data from disk
        guard let data = loadData(for: entry) else {
            // Data file missing, remove from index
            index.entries.removeValue(forKey: key)
            saveIndexAsync()
            return .miss
        }

        let staleWindow: TimeInterval = entry.metadata.cacheControl?.staleWhileRevalidate ?? 0

        if !entry.metadata.isExpired {
            if entry.metadata.requiresRevalidation {
                return .needsRevalidation(data, entry.metadata)
            }
            return .fresh(data, entry.metadata)
        }

        if entry.metadata.isStaleButRevalidatable(within: staleWindow) {
            return .stale(data, entry.metadata)
        }

        if entry.metadata.etag != nil || entry.metadata.lastModified != nil {
            return .needsRevalidation(data, entry.metadata)
        }

        // Entry is expired beyond stale window, remove it
        await removeEntry(for: key)
        return .miss
    }

    /// Updates cache entry after a 304 Not Modified response.
    /// - Parameters:
    ///   - request: The request used as cache key.
    ///   - response: The 304 response with potentially updated headers.
    public func updateAfterRevalidation(for request: URLRequest, response: HTTPURLResponse) async {
        let key: String = CacheKeyGenerator.cacheKey(for: request)
        guard var entry = index.entries[key] else { return }

        let newMetadata: CacheMetadata = CacheMetadataFactory.create(from: response, policy: cachePolicy)
        let ttl: TimeInterval = cachePolicy.ttl(for: response) ?? 0
        let updatedMetadata: CacheMetadata = CacheMetadata(
            etag: newMetadata.etag ?? entry.metadata.etag,
            lastModified: newMetadata.lastModified ?? entry.metadata.lastModified,
            cachedAt: Date(),
            expiresAt: ttl > 0 ? Date().addingTimeInterval(ttl) : entry.metadata.expiresAt,
            cacheControl: newMetadata.cacheControl ?? entry.metadata.cacheControl
        )

        entry = DiskCacheEntry(
            filename: entry.filename,
            metadata: updatedMetadata,
            size: entry.size,
            isCompressed: entry.isCompressed,
            lastAccessedAt: Date()
        )
        index.entries[key] = entry
        saveIndexAsync()
    }

    /// Retrieves metadata for a request without loading data.
    /// - Parameter request: The request to look up.
    /// - Returns: The cache metadata, or nil if not cached.
    public func metadata(for request: URLRequest) -> CacheMetadata? {
        let key: String = CacheKeyGenerator.cacheKey(for: request)
        return index.entries[key]?.metadata
    }

    /// Invalidates the cache entry for a specific request.
    /// - Parameter request: The request whose cache entry should be removed.
    public func invalidate(for request: URLRequest) async {
        let key: String = CacheKeyGenerator.cacheKey(for: request)
        await removeEntry(for: key)
    }

    /// Invalidates all cached entries.
    public func invalidateAll() async {
        for key in index.entries.keys {
            await removeEntry(for: key)
        }
    }

    /// Removes all expired entries from the cache.
    public func pruneExpired() async {
        let expiredKeys: [String] = index.entries.filter { $0.value.metadata.isExpired }.map { $0.key }
        for key in expiredKeys {
            await removeEntry(for: key)
        }
    }

    /// Removes entries older than the specified age.
    /// - Parameter maxAge: Maximum age in seconds.
    public func pruneOlderThan(_ maxAge: TimeInterval) async {
        let cutoff: Date = Date().addingTimeInterval(-maxAge)
        let oldKeys: [String] = index.entries.filter { $0.value.lastAccessedAt < cutoff }.map { $0.key }
        for key in oldKeys {
            await removeEntry(for: key)
        }
    }

    /// Invalidates entries matching a URL pattern.
    /// - Parameter pattern: A string pattern to match against cache keys.
    public func invalidateMatching(pattern: String) async {
        let matchingKeys: [String] = index.entries.keys.filter { $0.contains(pattern) }
        for key in matchingKeys {
            await removeEntry(for: key)
        }
    }

    /// The current number of cached entries.
    public var count: Int {
        index.entries.count
    }

    /// The current total size of cached data in bytes.
    public var totalSize: Int {
        index.totalSize
    }

    /// Flushes any pending index writes to disk immediately.
    /// Useful for ensuring data persistence before app termination or for testing.
    ///
    /// This method ensures the current index state is written by:
    /// 1. Scheduling a synchronous write with the current index state
    /// 2. Flushing any pending writes immediately
    /// - Returns: True if a write was performed, false if no pending write.
    @discardableResult
    public func flushIndex() async -> Bool {
        // First, schedule the current index state synchronously to ensure it's captured
        await indexWriter.scheduleWriteAndWait(index: index)
        // Then flush immediately to bypass coalescing delay
        return await indexWriter.flush()
    }

    // MARK: - Private Methods

    private func store(data: Data, for request: URLRequest, metadata: CacheMetadata) async -> Bool {
        let key: String = CacheKeyGenerator.cacheKey(for: request)
        let filename: String = CacheKeyGenerator.filename(for: key)

        // Compress if above threshold
        let shouldCompress: Bool = data.count >= configuration.compressionThreshold
        let dataToStore: Data
        let actuallyCompressed: Bool
        if shouldCompress, let compressed = compress(data), compressed.count < data.count {
            dataToStore = compressed
            actuallyCompressed = true
        } else {
            dataToStore = data
            actuallyCompressed = false
        }

        // Check if adding this entry would exceed max size
        let newSize: Int = dataToStore.count
        let existingSize: Int = index.entries[key]?.size ?? 0
        let projectedSize: Int = index.totalSize - existingSize + newSize

        if projectedSize > configuration.maxSize {
            // Need to evict entries
            await evictLRU(toFree: projectedSize - configuration.maxSize + newSize)
        }

        // Write data to disk
        let fileURL: URL = entriesDirectory.appendingPathComponent(filename)
        do {
            var options: Data.WritingOptions = [.atomic]
            if configuration.useFileProtection {
                options.insert(.completeFileProtection)
            }
            try dataToStore.write(to: fileURL, options: options)
        } catch {
            return false
        }

        // Update index
        let entry: DiskCacheEntry = DiskCacheEntry(
            filename: filename,
            metadata: metadata,
            size: newSize,
            isCompressed: actuallyCompressed
        )
        index.entries[key] = entry
        saveIndexAsync()

        return true
    }

    private func loadData(for entry: DiskCacheEntry) -> Data? {
        let fileURL: URL = entriesDirectory.appendingPathComponent(entry.filename)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        if entry.isCompressed {
            return decompress(data)
        }
        return data
    }

    private func removeEntry(for key: String) async {
        guard let entry = index.entries[key] else { return }

        let fileURL: URL = entriesDirectory.appendingPathComponent(entry.filename)
        try? fileManager.removeItem(at: fileURL)
        index.entries.removeValue(forKey: key)
        saveIndexAsync()
    }

    private func evictLRU(toFree bytesNeeded: Int) async {
        var freedBytes: Int = 0

        // First, remove expired entries
        let expiredKeys: [String] = index.entries.filter { $0.value.metadata.isExpired }.map { $0.key }
        for key in expiredKeys {
            if let entry = index.entries[key] {
                freedBytes += entry.size
                await removeEntry(for: key)
            }
            if freedBytes >= bytesNeeded {
                return
            }
        }

        // Then, remove by LRU order
        let sortedByAccess: [(String, DiskCacheEntry)] = index.entries
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }

        for (key, entry) in sortedByAccess {
            freedBytes += entry.size
            await removeEntry(for: key)
            if freedBytes >= bytesNeeded {
                return
            }
        }
    }

    // MARK: - Compression

    private func compress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .lzfse) as Data
    }

    private func decompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .lzfse) as Data
    }

    // MARK: - File System Operations

    private func createDirectoryStructure() throws {
        try fileManager.createDirectory(at: entriesDirectory, withIntermediateDirectories: true)

        // Write version file
        let versionData: Data = Data("\(DiskCacheIndex.currentVersion)".utf8)
        try versionData.write(to: versionFileURL, options: .atomic)
    }

    private func loadOrMigrateIndex() async throws {
        guard fileManager.fileExists(atPath: indexFileURL.path) else {
            // No existing index, start fresh
            index = DiskCacheIndex()
            return
        }

        do {
            let data: Data = try Data(contentsOf: indexFileURL)
            let loadedIndex: DiskCacheIndex = try JSONDecoder().decode(DiskCacheIndex.self, from: data)

            if loadedIndex.version < DiskCacheIndex.currentVersion {
                // Perform migration if needed
                index = try await migrateIndex(from: loadedIndex)
            } else {
                index = loadedIndex
            }

            // Validate entries exist on disk
            await validateEntries()
        } catch {
            // Index corrupted, try to recover from backup or start fresh
            if let backupIndex = try? loadBackupIndex() {
                index = backupIndex
                await validateEntries()
            } else {
                // Clear everything and start fresh
                try? fileManager.removeItem(at: cacheDirectory)
                try createDirectoryStructure()
                index = DiskCacheIndex()
            }
        }
    }

    private func migrateIndex(from oldIndex: DiskCacheIndex) async throws -> DiskCacheIndex {
        // Currently only version 1 exists, so no migration needed yet
        // Future migrations would be handled here
        return oldIndex
    }

    private func validateEntries() async {
        var keysToRemove: [String] = []
        for (key, entry) in index.entries {
            let fileURL: URL = entriesDirectory.appendingPathComponent(entry.filename)
            if !fileManager.fileExists(atPath: fileURL.path) {
                keysToRemove.append(key)
            }
        }
        for key in keysToRemove {
            index.entries.removeValue(forKey: key)
        }
        if !keysToRemove.isEmpty {
            saveIndexAsync()
        }
    }

    private func saveIndexAsync() {
        // Schedule a write with the serialized index writer.
        // The writer coalesces rapid writes and ensures only the latest state is persisted.
        indexWriter.scheduleWrite(index: index)
    }

    private func loadBackupIndex() throws -> DiskCacheIndex? {
        let backupURL: URL = cacheDirectory.appendingPathComponent("index.backup.json")
        guard fileManager.fileExists(atPath: backupURL.path) else {
            return nil
        }
        let data: Data = try Data(contentsOf: backupURL)
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiskCacheIndex.self, from: data)
    }
}

// MARK: - Disk Cache Error

/// Errors that can occur during disk cache operations.
public enum DiskCacheError: Error, Sendable {
    /// The caches directory could not be found.
    case directoryNotFound

    /// Failed to create the cache directory structure.
    case directoryCreationFailed

    /// Failed to write data to disk.
    case writeFailed

    /// Failed to read data from disk.
    case readFailed

    /// The index file is corrupted.
    case indexCorrupted

    /// The entry size exceeds the maximum allowed.
    case entrySizeExceeded
}

// MARK: - Index Writer

/// A serialized index writer that coalesces rapid writes to prevent race conditions.
/// Uses an internal actor to serialize all write operations and coalesces multiple rapid
/// write requests into a single disk write.
///
/// This class is `Sendable` and thread-safe. It can be called from any isolation domain
/// (including the `DiskCache` actor) without synchronization concerns. All write operations
/// are automatically serialized through the internal `IndexWriteCoordinator` actor.
internal final class IndexWriter: Sendable {
    private let coordinator: IndexWriteCoordinator

    /// Creates an index writer for the specified URLs.
    /// - Parameters:
    ///   - indexURL: The URL where the index file should be written.
    ///   - cacheDirectory: The cache directory for backup files.
    ///   - coalesceInterval: Time to wait before writing (default 100ms for coalescing).
    init(indexURL: URL, cacheDirectory: URL, coalesceInterval: TimeInterval = 0.1) {
        self.coordinator = IndexWriteCoordinator(
            indexURL: indexURL,
            cacheDirectory: cacheDirectory,
            coalesceInterval: coalesceInterval
        )
    }

    /// Schedules an index write. Multiple rapid calls will be coalesced into a single write.
    /// Only the most recent index state will be written to disk.
    /// This method is safe to call from any context.
    /// - Parameter index: The index to write.
    func scheduleWrite(index: DiskCacheIndex) {
        Task {
            await coordinator.scheduleWrite(index: index)
        }
    }

    /// Forces an immediate write of any pending index, bypassing coalescing.
    /// Useful for testing and ensuring data is persisted before shutdown.
    /// - Returns: True if a write was performed, false if no pending write.
    @discardableResult
    func flush() async -> Bool {
        await coordinator.flush()
    }

    /// Schedules a write and waits for it to be registered in the coordinator.
    /// Used when immediate flushing is needed after the write.
    func scheduleWriteAndWait(index: DiskCacheIndex) async {
        await coordinator.scheduleWrite(index: index)
    }
}

/// Internal actor that coordinates serialized index writes with coalescing.
private actor IndexWriteCoordinator {
    private let indexURL: URL
    private let cacheDirectory: URL
    private var pendingIndex: DiskCacheIndex?
    private var writeTask: Task<Void, Never>?
    private let coalesceInterval: UInt64 // nanoseconds

    init(indexURL: URL, cacheDirectory: URL, coalesceInterval: TimeInterval) {
        self.indexURL = indexURL
        self.cacheDirectory = cacheDirectory
        self.coalesceInterval = UInt64(coalesceInterval * 1_000_000_000)
    }

    /// Schedules an index write with coalescing.
    func scheduleWrite(index: DiskCacheIndex) {
        // Always update the pending index to the latest state
        pendingIndex = index

        // If a write is already scheduled, it will pick up the latest pendingIndex
        guard writeTask == nil else { return }

        // Schedule a new write task with coalescing delay
        writeTask = Task {
            // Wait for coalesce interval to batch rapid updates
            try? await Task.sleep(nanoseconds: self.coalesceInterval)

            // Check if task was cancelled during sleep (e.g., via flush())
            guard !Task.isCancelled else {
                self.writeTask = nil
                return
            }

            // Perform the write with the latest state
            await self.performCoalescedWrite()
        }
    }

    /// Performs the coalesced write, consuming the pending state.
    private func performCoalescedWrite() {
        guard let indexToWrite = pendingIndex else {
            writeTask = nil
            return
        }

        pendingIndex = nil
        writeTask = nil

        // Perform the actual I/O (this is synchronous but safe within the actor)
        performWriteSync(index: indexToWrite)
    }

    /// Synchronous write operation.
    private func performWriteSync(index: DiskCacheIndex) {
        let fm: FileManager = FileManager()

        do {
            // Backup current index first
            if fm.fileExists(atPath: indexURL.path) {
                let backupURL: URL = cacheDirectory.appendingPathComponent("index.backup.json")
                try? fm.removeItem(at: backupURL)
                try? fm.copyItem(at: indexURL, to: backupURL)
            }

            let encoder: JSONEncoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data: Data = try encoder.encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // Log error in production, but don't throw
            // The backup mechanism allows recovery on next load
        }
    }

    /// Forces an immediate write of any pending index, bypassing coalescing.
    /// Waits for any in-flight write task to complete first.
    @discardableResult
    func flush() async -> Bool {
        // Wait for any in-flight write task to complete
        if let task = writeTask {
            _ = await task.value
        }

        // After the task completes, check for any pending writes that arrived
        // during the wait or after task completion but before we checked.
        // This handles the race where scheduleWrite() is called while flush() waits.
        guard let indexToWrite = pendingIndex else { return false }

        // Cancel any newly scheduled task since we're writing immediately
        writeTask?.cancel()
        writeTask = nil
        pendingIndex = nil

        performWriteSync(index: indexToWrite)
        return true
    }
}
