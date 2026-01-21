import Testing
import Foundation
@testable import NetKit

// MARK: - DiskCacheConfiguration Tests

@Suite("DiskCacheConfiguration Tests")
struct DiskCacheConfigurationTests {
    @Test("Default configuration has expected values")
    func defaultConfiguration() {
        let config: DiskCacheConfiguration = .default

        #expect(config.maxSize == 50 * 1024 * 1024)
        #expect(config.maxEntrySize == 5 * 1024 * 1024)
        #expect(config.compressionThreshold == 1024)
        #expect(config.useFileProtection == false)
        #expect(config.directoryName == "com.netkit.cache")
    }

    @Test("Custom configuration is created correctly")
    func customConfiguration() {
        let config: DiskCacheConfiguration = DiskCacheConfiguration(
            maxSize: 100 * 1024 * 1024,
            maxEntrySize: 10 * 1024 * 1024,
            compressionThreshold: 2048,
            useFileProtection: true,
            directoryName: "custom.cache"
        )

        #expect(config.maxSize == 100 * 1024 * 1024)
        #expect(config.maxEntrySize == 10 * 1024 * 1024)
        #expect(config.compressionThreshold == 2048)
        #expect(config.useFileProtection == true)
        #expect(config.directoryName == "custom.cache")
    }
}

// MARK: - CacheStorageType Tests

@Suite("CacheStorageType Tests")
struct CacheStorageTypeTests {
    @Test("Storage types are distinct")
    func storageTypesDistinct() {
        let memory: CacheStorageType = .memory
        let disk: CacheStorageType = .disk
        let hybrid: CacheStorageType = .hybrid

        switch memory {
        case .memory:
            break
        case .disk, .hybrid:
            Issue.record("Expected memory type")
        }

        switch disk {
        case .disk:
            break
        case .memory, .hybrid:
            Issue.record("Expected disk type")
        }

        switch hybrid {
        case .hybrid:
            break
        case .memory, .disk:
            Issue.record("Expected hybrid type")
        }
    }
}

// MARK: - DiskCacheEntry Tests

@Suite("DiskCacheEntry Tests")
struct DiskCacheEntryTests {
    @Test("Entry is created with correct values")
    func entryCreation() {
        let metadata: CacheMetadata = CacheMetadata(
            etag: "\"abc123\"",
            cachedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )
        let entry: DiskCacheEntry = DiskCacheEntry(
            filename: "test.data",
            metadata: metadata,
            size: 1024,
            isCompressed: true
        )

        #expect(entry.filename == "test.data")
        #expect(entry.metadata.etag == "\"abc123\"")
        #expect(entry.size == 1024)
        #expect(entry.isCompressed == true)
    }

    @Test("Entry is Codable")
    func entryCodable() throws {
        let metadata: CacheMetadata = CacheMetadata(
            etag: "\"test\"",
            cachedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )
        let entry: DiskCacheEntry = DiskCacheEntry(
            filename: "test.data",
            metadata: metadata,
            size: 2048,
            isCompressed: false,
            lastAccessedAt: Date()
        )

        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data = try encoder.encode(entry)

        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: DiskCacheEntry = try decoder.decode(DiskCacheEntry.self, from: data)

        #expect(decoded.filename == entry.filename)
        #expect(decoded.size == entry.size)
        #expect(decoded.isCompressed == entry.isCompressed)
        #expect(decoded.metadata.etag == entry.metadata.etag)
    }
}

// MARK: - CacheKeyGenerator Tests

@Suite("CacheKeyGenerator Tests")
struct CacheKeyGeneratorTests {
    @Test("Generates cache key from request")
    func generatesCacheKey() {
        var request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/users/123")!)
        request.httpMethod = "GET"

        let key: String = CacheKeyGenerator.cacheKey(for: request)

        #expect(key.contains("GET"))
        #expect(key.contains("https://api.example.com/users/123"))
    }

    @Test("Cache key includes relevant headers")
    func cacheKeyIncludesHeaders() {
        var request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/data")!)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("en-US", forHTTPHeaderField: "Accept-Language")

        let key: String = CacheKeyGenerator.cacheKey(for: request)

        #expect(key.contains("Accept:application/json"))
        #expect(key.contains("Accept-Language:en-US"))
    }

    @Test("Different requests generate different keys")
    func differentRequestsDifferentKeys() {
        let request1: URLRequest = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        let request2: URLRequest = URLRequest(url: URL(string: "https://api.example.com/users/2")!)

        let key1: String = CacheKeyGenerator.cacheKey(for: request1)
        let key2: String = CacheKeyGenerator.cacheKey(for: request2)

        #expect(key1 != key2)
    }

    @Test("Generates consistent filename from cache key")
    func generatesFilename() {
        let cacheKey: String = "GET|https://api.example.com/users|Accept:application/json"

        let filename1: String = CacheKeyGenerator.filename(for: cacheKey)
        let filename2: String = CacheKeyGenerator.filename(for: cacheKey)

        #expect(filename1 == filename2)
        #expect(filename1.count == 64) // SHA256 hex string length
    }

    @Test("Different cache keys generate different filenames")
    func differentCacheKeysDifferentFilenames() {
        let key1: String = "GET|https://api.example.com/users/1"
        let key2: String = "GET|https://api.example.com/users/2"

        let filename1: String = CacheKeyGenerator.filename(for: key1)
        let filename2: String = CacheKeyGenerator.filename(for: key2)

        #expect(filename1 != filename2)
    }
}

// MARK: - DiskCache Tests

@Suite("DiskCache Tests")
struct DiskCacheTests {
    private func createTestConfiguration() -> DiskCacheConfiguration {
        DiskCacheConfiguration(
            maxSize: 1024 * 1024, // 1MB
            maxEntrySize: 100 * 1024, // 100KB
            compressionThreshold: 1024,
            useFileProtection: false,
            directoryName: "com.netkit.cache.test.\(UUID().uuidString)"
        )
    }

    @Test("Factory method creates ready-to-use cache")
    func factoryMethodCreatesReadyCache() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try await DiskCache.create(configuration: config)

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/factory-test")!)
        let data: Data = "factory test data".data(using: .utf8)!

        let stored: Bool = await cache.store(data: data, for: request, ttl: 3600)
        #expect(stored == true)

        let retrieved: Data? = await cache.retrieve(for: request)
        #expect(retrieved == data)
    }

    @Test("Store and retrieve data")
    func storeAndRetrieve() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data: Data = "test data for disk cache".data(using: .utf8)!

        let stored: Bool = await cache.store(data: data, for: request, ttl: 3600)
        #expect(stored == true)

        let retrieved: Data? = await cache.retrieve(for: request)
        #expect(retrieved == data)
    }

    @Test("Returns nil for non-existent entry")
    func nonExistentEntry() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/missing")!)

        let result: Data? = await cache.retrieve(for: request)
        #expect(result == nil)
    }

    @Test("Invalidate single entry")
    func invalidateSingleEntry() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data: Data = "test data".data(using: .utf8)!

        await cache.store(data: data, for: request, ttl: 3600)
        await cache.invalidate(for: request)

        let result: Data? = await cache.retrieve(for: request)
        #expect(result == nil)
    }

    @Test("Invalidate all entries")
    func invalidateAllEntries() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request1: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test1")!)
        let request2: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test2")!)

        await cache.store(data: Data("data1".utf8), for: request1, ttl: 3600)
        await cache.store(data: Data("data2".utf8), for: request2, ttl: 3600)

        #expect(await cache.count == 2)

        await cache.invalidateAll()

        #expect(await cache.count == 0)
    }

    @Test("Expired entries return miss")
    func expiredEntriesReturnMiss() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data: Data = "test data".data(using: .utf8)!

        await cache.store(data: data, for: request, ttl: 0.1)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

        let result: CacheRetrievalResult = await cache.retrieveWithMetadata(for: request)
        #expect(result.isMiss == true)
    }

    @Test("Store respects max entry size")
    func respectsMaxEntrySize() async throws {
        let config: DiskCacheConfiguration = DiskCacheConfiguration(
            maxSize: 1024 * 1024,
            maxEntrySize: 100, // Very small max entry
            compressionThreshold: 50,
            directoryName: "com.netkit.cache.test.\(UUID().uuidString)"
        )
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/large")!)
        let largeData: Data = Data(repeating: 0, count: 200) // Exceeds max entry size

        let stored: Bool = await cache.store(data: largeData, for: request, ttl: 3600)
        #expect(stored == false)
    }

    @Test("Compression reduces data size")
    func compressionReducesSize() async throws {
        let config: DiskCacheConfiguration = DiskCacheConfiguration(
            maxSize: 1024 * 1024,
            maxEntrySize: 100 * 1024,
            compressionThreshold: 100, // Low threshold
            directoryName: "com.netkit.cache.test.\(UUID().uuidString)"
        )
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/compressible")!)
        // Highly compressible data
        let compressibleData: Data = Data(repeating: 65, count: 2000)

        let stored: Bool = await cache.store(data: compressibleData, for: request, ttl: 3600)
        #expect(stored == true)

        // Verify data can be retrieved correctly
        let retrieved: Data? = await cache.retrieve(for: request)
        #expect(retrieved == compressibleData)

        // Total size should be less than original data
        #expect(await cache.totalSize < compressibleData.count)
    }

    @Test("LRU eviction removes oldest entries")
    func lruEvictionRemovesOldest() async throws {
        let config: DiskCacheConfiguration = DiskCacheConfiguration(
            maxSize: 250, // Very small cache - fits ~2 entries of 100 bytes
            maxEntrySize: 200,
            compressionThreshold: 10000, // Disable compression
            directoryName: "com.netkit.cache.test.\(UUID().uuidString)"
        )
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        // Store first entry with unique, non-compressible data
        let request1: URLRequest = URLRequest(url: URL(string: "https://api.example.com/old")!)
        var data1: Data = Data(count: 100)
        for i in 0..<100 { data1[i] = UInt8(i % 256) }
        await cache.store(data: data1, for: request1, ttl: 3600)

        // Wait a bit to ensure different timestamps
        try await Task.sleep(nanoseconds: 50_000_000)

        // Store second entry
        let request2: URLRequest = URLRequest(url: URL(string: "https://api.example.com/newer")!)
        var data2: Data = Data(count: 100)
        for i in 0..<100 { data2[i] = UInt8((i + 50) % 256) }
        await cache.store(data: data2, for: request2, ttl: 3600)

        // Wait a bit
        try await Task.sleep(nanoseconds: 50_000_000)

        // Store third entry - should evict the first (oldest by lastAccessedAt)
        let request3: URLRequest = URLRequest(url: URL(string: "https://api.example.com/newest")!)
        var data3: Data = Data(count: 100)
        for i in 0..<100 { data3[i] = UInt8((i + 100) % 256) }
        await cache.store(data: data3, for: request3, ttl: 3600)

        // First entry should be evicted
        let result1: Data? = await cache.retrieve(for: request1)
        #expect(result1 == nil)

        // Newest entry should exist
        let result3: Data? = await cache.retrieve(for: request3)
        #expect(result3 == data3)
    }

    @Test("Prune expired removes only expired entries")
    func pruneExpiredRemovesOnlyExpired() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let expiredRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/expired")!)
        let validRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/valid")!)

        await cache.store(data: Data("expired".utf8), for: expiredRequest, ttl: 0.1)
        await cache.store(data: Data("valid".utf8), for: validRequest, ttl: 3600)

        try await Task.sleep(nanoseconds: 200_000_000) // Wait for expiration

        await cache.pruneExpired()

        let expiredResult: Data? = await cache.retrieve(for: expiredRequest)
        let validResult: Data? = await cache.retrieve(for: validRequest)

        #expect(expiredResult == nil)
        #expect(validResult == Data("valid".utf8))
    }

    @Test("Prune older than removes old entries")
    func pruneOlderThanRemovesOld() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let oldRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/old")!)
        await cache.store(data: Data("old".utf8), for: oldRequest, ttl: 3600)

        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

        let newRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/new")!)
        await cache.store(data: Data("new".utf8), for: newRequest, ttl: 3600)

        // Prune entries older than 0.1 seconds
        await cache.pruneOlderThan(0.1)

        let oldResult: Data? = await cache.retrieve(for: oldRequest)
        let newResult: Data? = await cache.retrieve(for: newRequest)

        #expect(oldResult == nil)
        #expect(newResult == Data("new".utf8))
    }

    @Test("Invalidate matching removes matching entries")
    func invalidateMatchingRemovesMatching() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let usersRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        let postsRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/posts/1")!)

        await cache.store(data: Data("user".utf8), for: usersRequest, ttl: 3600)
        await cache.store(data: Data("post".utf8), for: postsRequest, ttl: 3600)

        await cache.invalidateMatching(pattern: "/users/")

        let usersResult: Data? = await cache.retrieve(for: usersRequest)
        let postsResult: Data? = await cache.retrieve(for: postsRequest)

        #expect(usersResult == nil)
        #expect(postsResult == Data("post".utf8))
    }

    @Test("retrieveWithMetadata returns fresh for valid entry")
    func retrieveWithMetadataFresh() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=3600", "ETag": "\"abc123\""]
        )!
        let data: Data = "test".data(using: .utf8)!

        await cache.store(data: data, for: request, response: response)
        let result: CacheRetrievalResult = await cache.retrieveWithMetadata(for: request)

        if case .fresh(let retrievedData, let metadata) = result {
            #expect(retrievedData == data)
            #expect(metadata.etag == "\"abc123\"")
        } else {
            Issue.record("Expected fresh result")
        }
    }

    @Test("Store respects no-store directive")
    func storeRespectsNoStore() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "no-store"]
        )!
        let data: Data = "test".data(using: .utf8)!

        let stored: Bool = await cache.store(data: data, for: request, response: response)

        #expect(stored == false)
        #expect(await cache.count == 0)
    }

    @Test("Update after revalidation refreshes entry")
    func updateAfterRevalidation() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let initialResponse: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=100", "ETag": "\"old\""]
        )!
        let data: Data = "test".data(using: .utf8)!

        await cache.store(data: data, for: request, response: initialResponse)

        let revalidationResponse: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/test")!,
            statusCode: 304,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=3600", "ETag": "\"new\""]
        )!

        await cache.updateAfterRevalidation(for: request, response: revalidationResponse)

        let metadata: CacheMetadata? = await cache.metadata(for: request)
        #expect(metadata?.etag == "\"new\"")
    }

    @Test("Count returns correct number of entries")
    func countReturnsCorrectNumber() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        #expect(await cache.count == 0)

        let request1: URLRequest = URLRequest(url: URL(string: "https://api.example.com/1")!)
        let request2: URLRequest = URLRequest(url: URL(string: "https://api.example.com/2")!)

        await cache.store(data: Data("1".utf8), for: request1, ttl: 3600)
        #expect(await cache.count == 1)

        await cache.store(data: Data("2".utf8), for: request2, ttl: 3600)
        #expect(await cache.count == 2)

        await cache.invalidate(for: request1)
        #expect(await cache.count == 1)
    }

    @Test("Total size tracks correctly")
    func totalSizeTracksCorrectly() async throws {
        let config: DiskCacheConfiguration = DiskCacheConfiguration(
            maxSize: 1024 * 1024,
            maxEntrySize: 100 * 1024,
            compressionThreshold: 10000, // High threshold to disable compression
            directoryName: "com.netkit.cache.test.\(UUID().uuidString)"
        )
        let cache: DiskCache = try DiskCache(configuration: config)
        try await cache.setup()

        #expect(await cache.totalSize == 0)

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data: Data = Data(repeating: 65, count: 100)

        await cache.store(data: data, for: request, ttl: 3600)

        let totalSize: Int = await cache.totalSize
        #expect(totalSize == 100)
    }
}

// MARK: - HybridCache Tests

@Suite("HybridCache Tests")
struct HybridCacheTests {
    private func createTestConfiguration() -> DiskCacheConfiguration {
        DiskCacheConfiguration(
            maxSize: 1024 * 1024,
            maxEntrySize: 100 * 1024,
            compressionThreshold: 1024,
            useFileProtection: false,
            directoryName: "com.netkit.cache.hybrid.test.\(UUID().uuidString)"
        )
    }

    @Test("Factory method creates ready-to-use hybrid cache")
    func factoryMethodCreatesReadyCache() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: HybridCache = try await HybridCache.create(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/factory-test")!)
        let data: Data = "hybrid factory test".data(using: .utf8)!

        let stored: Bool = await cache.store(data: data, for: request, ttl: 3600)
        #expect(stored == true)
        #expect(await cache.memoryCount == 1)
        #expect(await cache.diskCount == 1)
    }

    @Test("Store in both memory and disk")
    func storeInBothCaches() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: HybridCache = try HybridCache(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data: Data = "hybrid cache test".data(using: .utf8)!

        let stored: Bool = await cache.store(data: data, for: request, ttl: 3600)
        #expect(stored == true)

        #expect(await cache.memoryCount == 1)
        #expect(await cache.diskCount == 1)
    }

    @Test("Retrieve from memory first")
    func retrieveFromMemoryFirst() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: HybridCache = try HybridCache(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data: Data = "test data".data(using: .utf8)!

        await cache.store(data: data, for: request, ttl: 3600)

        // First retrieval - should be from memory
        let result: Data? = await cache.retrieve(for: request)
        #expect(result == data)
    }

    @Test("Invalidate clears both caches")
    func invalidateClearsBothCaches() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: HybridCache = try HybridCache(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        await cache.store(data: Data("test".utf8), for: request, ttl: 3600)

        await cache.invalidate(for: request)

        #expect(await cache.memoryCount == 0)
        #expect(await cache.diskCount == 0)
    }

    @Test("Invalidate all clears both caches")
    func invalidateAllClearsBothCaches() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: HybridCache = try HybridCache(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )
        try await cache.setup()

        let request1: URLRequest = URLRequest(url: URL(string: "https://api.example.com/1")!)
        let request2: URLRequest = URLRequest(url: URL(string: "https://api.example.com/2")!)

        await cache.store(data: Data("1".utf8), for: request1, ttl: 3600)
        await cache.store(data: Data("2".utf8), for: request2, ttl: 3600)

        await cache.invalidateAll()

        #expect(await cache.memoryCount == 0)
        #expect(await cache.diskCount == 0)
    }

    @Test("Prune expired clears both caches")
    func pruneExpiredClearsBothCaches() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: HybridCache = try HybridCache(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )
        try await cache.setup()

        let expiredRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/expired")!)
        let validRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/valid")!)

        await cache.store(data: Data("expired".utf8), for: expiredRequest, ttl: 0.1)
        await cache.store(data: Data("valid".utf8), for: validRequest, ttl: 3600)

        try await Task.sleep(nanoseconds: 200_000_000)

        await cache.pruneExpired()

        let expiredResult: Data? = await cache.retrieve(for: expiredRequest)
        let validResult: Data? = await cache.retrieve(for: validRequest)

        #expect(expiredResult == nil)
        #expect(validResult == Data("valid".utf8))
    }

    @Test("Metadata retrieval checks both caches")
    func metadataRetrievalChecksBothCaches() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: HybridCache = try HybridCache(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=3600", "ETag": "\"test\""]
        )!

        await cache.store(data: Data("test".utf8), for: request, response: response)

        let metadata: CacheMetadata? = await cache.metadata(for: request)
        #expect(metadata?.etag == "\"test\"")
    }

    @Test("Update after revalidation updates both caches")
    func updateAfterRevalidationUpdatesBothCaches() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: HybridCache = try HybridCache(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let initialResponse: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=100", "ETag": "\"v1\""]
        )!

        await cache.store(data: Data("test".utf8), for: request, response: initialResponse)

        let revalidationResponse: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/test")!,
            statusCode: 304,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=3600", "ETag": "\"v2\""]
        )!

        await cache.updateAfterRevalidation(for: request, response: revalidationResponse)

        let metadata: CacheMetadata? = await cache.metadata(for: request)
        #expect(metadata?.etag == "\"v2\"")
    }

    @Test("Disk size tracking")
    func diskSizeTracking() async throws {
        let config: DiskCacheConfiguration = DiskCacheConfiguration(
            maxSize: 1024 * 1024,
            maxEntrySize: 100 * 1024,
            compressionThreshold: 10000, // High to avoid compression
            directoryName: "com.netkit.cache.hybrid.test.\(UUID().uuidString)"
        )
        let cache: HybridCache = try HybridCache(
            memoryMaxEntries: 100,
            diskConfiguration: config
        )
        try await cache.setup()

        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data: Data = Data(repeating: 65, count: 500)

        await cache.store(data: data, for: request, ttl: 3600)

        let diskSize: Int = await cache.diskSize
        #expect(diskSize == 500)
    }
}

// MARK: - DiskCacheError Tests

@Suite("DiskCacheError Tests")
struct DiskCacheErrorTests {
    @Test("Error cases are distinct")
    func errorCasesDistinct() {
        let directoryNotFound: DiskCacheError = .directoryNotFound
        let directoryCreationFailed: DiskCacheError = .directoryCreationFailed
        let writeFailed: DiskCacheError = .writeFailed
        let readFailed: DiskCacheError = .readFailed
        let indexCorrupted: DiskCacheError = .indexCorrupted
        let entrySizeExceeded: DiskCacheError = .entrySizeExceeded

        // Just verify they can be created and are distinct types
        switch directoryNotFound {
        case .directoryNotFound:
            break
        default:
            Issue.record("Expected directoryNotFound")
        }

        switch directoryCreationFailed {
        case .directoryCreationFailed:
            break
        default:
            Issue.record("Expected directoryCreationFailed")
        }

        switch writeFailed {
        case .writeFailed:
            break
        default:
            Issue.record("Expected writeFailed")
        }

        switch readFailed {
        case .readFailed:
            break
        default:
            Issue.record("Expected readFailed")
        }

        switch indexCorrupted {
        case .indexCorrupted:
            break
        default:
            Issue.record("Expected indexCorrupted")
        }

        switch entrySizeExceeded {
        case .entrySizeExceeded:
            break
        default:
            Issue.record("Expected entrySizeExceeded")
        }
    }
}

// MARK: - DiskCache Concurrency Tests

@Suite("DiskCache Concurrency Tests")
struct DiskCacheConcurrencyTests {
    private func createTestConfiguration() -> DiskCacheConfiguration {
        DiskCacheConfiguration(
            maxSize: 10 * 1024 * 1024, // 10MB
            maxEntrySize: 1 * 1024 * 1024, // 1MB
            compressionThreshold: 10000, // High to avoid compression
            useFileProtection: false,
            directoryName: "com.netkit.cache.concurrency.test.\(UUID().uuidString)"
        )
    }

    @Test("Concurrent stores do not lose entries")
    func concurrentStoresNoLostEntries() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try await DiskCache.create(configuration: config)

        let entryCount: Int = 50

        // Store entries concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<entryCount {
                group.addTask {
                    let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/concurrent/\(i)")!)
                    let data: Data = "data-\(i)".data(using: .utf8)!
                    await cache.store(data: data, for: request, ttl: 3600)
                }
            }
        }

        // Flush to ensure all writes are persisted
        await cache.flushIndex()

        // Verify all entries exist
        let count: Int = await cache.count
        #expect(count == entryCount, "Expected \(entryCount) entries, got \(count)")

        // Verify each entry can be retrieved
        for i in 0..<entryCount {
            let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/concurrent/\(i)")!)
            let retrieved: Data? = await cache.retrieve(for: request)
            let expected: Data = "data-\(i)".data(using: .utf8)!
            #expect(retrieved == expected, "Entry \(i) not found or corrupted")
        }
    }

    @Test("Concurrent store and retrieve operations are consistent")
    func concurrentStoreAndRetrieve() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try await DiskCache.create(configuration: config)

        let operationCount: Int = 100

        // Pre-populate some entries
        for i in 0..<20 {
            let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/prepopulated/\(i)")!)
            let data: Data = "prepopulated-\(i)".data(using: .utf8)!
            await cache.store(data: data, for: request, ttl: 3600)
        }

        await cache.flushIndex()

        // Mix of concurrent stores and retrieves
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<operationCount {
                if i % 2 == 0 {
                    // Store new entry
                    group.addTask {
                        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/new/\(i)")!)
                        let data: Data = "new-\(i)".data(using: .utf8)!
                        await cache.store(data: data, for: request, ttl: 3600)
                    }
                } else {
                    // Retrieve existing entry
                    group.addTask {
                        let index: Int = i % 20
                        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/prepopulated/\(index)")!)
                        let _ = await cache.retrieve(for: request)
                    }
                }
            }
        }

        await cache.flushIndex()

        // Verify prepopulated entries are still intact
        for i in 0..<20 {
            let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/prepopulated/\(i)")!)
            let retrieved: Data? = await cache.retrieve(for: request)
            let expected: Data = "prepopulated-\(i)".data(using: .utf8)!
            #expect(retrieved == expected, "Prepopulated entry \(i) corrupted")
        }
    }

    @Test("Concurrent store and invalidate operations are safe")
    func concurrentStoreAndInvalidate() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try await DiskCache.create(configuration: config)

        let entryCount: Int = 30

        // Concurrent stores and invalidations
        await withTaskGroup(of: Void.self) { group in
            // Store entries
            for i in 0..<entryCount {
                group.addTask {
                    let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/mixed/\(i)")!)
                    let data: Data = "mixed-\(i)".data(using: .utf8)!
                    await cache.store(data: data, for: request, ttl: 3600)
                }
            }

            // Invalidate some entries concurrently
            for i in stride(from: 0, to: entryCount, by: 3) {
                group.addTask {
                    // Small delay to allow some stores to complete
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/mixed/\(i)")!)
                    await cache.invalidate(for: request)
                }
            }
        }

        await cache.flushIndex()

        // Verify invalidated entries are gone and others remain
        for i in 0..<entryCount {
            let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/mixed/\(i)")!)
            let retrieved: Data? = await cache.retrieve(for: request)

            if i % 3 == 0 {
                // Should be invalidated
                #expect(retrieved == nil, "Entry \(i) should have been invalidated")
            } else {
                // Should still exist
                let expected: Data = "mixed-\(i)".data(using: .utf8)!
                #expect(retrieved == expected, "Entry \(i) should still exist")
            }
        }
    }

    @Test("Rapid sequential writes are coalesced correctly")
    func rapidWritesCoalesced() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try await DiskCache.create(configuration: config)

        // Perform many rapid stores (should be coalesced)
        for i in 0..<100 {
            let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/rapid/\(i)")!)
            let data: Data = "rapid-\(i)".data(using: .utf8)!
            await cache.store(data: data, for: request, ttl: 3600)
        }

        // Flush to ensure final state is written
        await cache.flushIndex()

        // Verify all entries exist despite rapid writes
        let count: Int = await cache.count
        #expect(count == 100)

        // Verify last entry is correct
        let lastRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/rapid/99")!)
        let lastData: Data? = await cache.retrieve(for: lastRequest)
        #expect(lastData == "rapid-99".data(using: .utf8)!)
    }

    @Test("High-frequency operations stress test")
    func highFrequencyStressTest() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let cache: DiskCache = try await DiskCache.create(configuration: config)

        let operationsPerTask: Int = 50
        let taskCount: Int = 10

        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<taskCount {
                group.addTask {
                    for opIndex in 0..<operationsPerTask {
                        let key: Int = taskIndex * operationsPerTask + opIndex
                        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/stress/\(key)")!)
                        let data: Data = "stress-\(key)".data(using: .utf8)!

                        // Mix of operations
                        switch opIndex % 4 {
                        case 0:
                            await cache.store(data: data, for: request, ttl: 3600)
                        case 1:
                            let _ = await cache.retrieve(for: request)
                        case 2:
                            let _ = await cache.retrieveWithMetadata(for: request)
                        case 3:
                            await cache.store(data: data, for: request, ttl: 3600)
                            let _ = await cache.retrieve(for: request)
                        default:
                            break
                        }
                    }
                }
            }
        }

        await cache.flushIndex()

        // Cache should be in a consistent state (no crash, no data loss for stored items)
        let count: Int = await cache.count
        #expect(count > 0, "Cache should have entries after stress test")

        // Verify we can still perform operations
        let testRequest: URLRequest = URLRequest(url: URL(string: "https://api.example.com/post-stress")!)
        let testData: Data = "post-stress".data(using: .utf8)!
        let stored: Bool = await cache.store(data: testData, for: testRequest, ttl: 3600)
        #expect(stored == true)
    }

    @Test("Index persistence survives reload after concurrent operations")
    func indexPersistsSurvivesReload() async throws {
        let config: DiskCacheConfiguration = createTestConfiguration()
        let entryCount: Int = 25

        // First cache instance - perform concurrent operations
        let cache1: DiskCache = try await DiskCache.create(configuration: config)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<entryCount {
                group.addTask {
                    let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/persist/\(i)")!)
                    let data: Data = "persist-\(i)".data(using: .utf8)!
                    await cache1.store(data: data, for: request, ttl: 3600)
                }
            }
        }

        // Wait for all fire-and-forget Tasks from concurrent stores to reach the coordinator.
        // The coalesce interval is 100ms, so we wait 150ms to ensure all writes are scheduled.
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms

        // Now flush to force immediate write (bypasses remaining coalesce delay)
        await cache1.flushIndex()

        // Create new cache instance with same configuration (simulates app restart)
        let cache2: DiskCache = try await DiskCache.create(configuration: config)

        // Verify all entries are present
        let count: Int = await cache2.count
        #expect(count == entryCount, "Expected \(entryCount) entries after reload, got \(count)")

        for i in 0..<entryCount {
            let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/persist/\(i)")!)
            let retrieved: Data? = await cache2.retrieve(for: request)
            let expected: Data = "persist-\(i)".data(using: .utf8)!
            #expect(retrieved == expected, "Entry \(i) not found after reload")
        }
    }
}
