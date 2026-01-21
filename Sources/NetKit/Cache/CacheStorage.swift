import CryptoKit
import Foundation

// MARK: - Cache Storage Type

/// Defines the storage strategy for the cache.
public enum CacheStorageType: Sendable {
    /// In-memory only cache. Fast but lost on app termination.
    case memory

    /// Disk-only cache. Persists between sessions but slower.
    case disk

    /// Hybrid cache with memory as L1 and disk as L2.
    /// Hot data stays in memory, all data persisted to disk.
    case hybrid
}

// MARK: - Disk Cache Configuration

/// Configuration options for disk cache.
public struct DiskCacheConfiguration: Sendable {
    /// Maximum total size in bytes for the disk cache.
    public let maxSize: Int

    /// Maximum size for a single entry in bytes.
    public let maxEntrySize: Int

    /// Minimum data size to apply compression (in bytes).
    public let compressionThreshold: Int

    /// Whether to use file protection for cached data.
    public let useFileProtection: Bool

    /// The subdirectory name within Caches directory.
    public let directoryName: String

    /// Default configuration with 50MB max size.
    public static let `default`: DiskCacheConfiguration = DiskCacheConfiguration(
        maxSize: 50 * 1024 * 1024,
        maxEntrySize: 5 * 1024 * 1024,
        compressionThreshold: 1024,
        useFileProtection: false,
        directoryName: "com.netkit.cache"
    )

    public init(
        maxSize: Int = 50 * 1024 * 1024,
        maxEntrySize: Int = 5 * 1024 * 1024,
        compressionThreshold: Int = 1024,
        useFileProtection: Bool = false,
        directoryName: String = "com.netkit.cache"
    ) {
        self.maxSize = maxSize
        self.maxEntrySize = maxEntrySize
        self.compressionThreshold = compressionThreshold
        self.useFileProtection = useFileProtection
        self.directoryName = directoryName
    }
}

// MARK: - Disk Cache Entry

/// Metadata for a disk cache entry, stored in the index file.
public struct DiskCacheEntry: Codable, Sendable {
    /// The filename of the cached data (SHA256 hash).
    public let filename: String

    /// The cache metadata (expiration, etag, etc.).
    public let metadata: CacheMetadata

    /// Size of the data on disk in bytes.
    public let size: Int

    /// Whether the data is compressed.
    public let isCompressed: Bool

    /// When this entry was last accessed (for LRU eviction).
    public var lastAccessedAt: Date

    public init(
        filename: String,
        metadata: CacheMetadata,
        size: Int,
        isCompressed: Bool,
        lastAccessedAt: Date = Date()
    ) {
        self.filename = filename
        self.metadata = metadata
        self.size = size
        self.isCompressed = isCompressed
        self.lastAccessedAt = lastAccessedAt
    }
}

// MARK: - Disk Cache Index

/// The index file structure for tracking all disk cache entries.
struct DiskCacheIndex: Codable {
    /// Index format version for migration support.
    let version: Int

    /// All cached entries keyed by their cache key.
    var entries: [String: DiskCacheEntry]

    /// Total size of all entries in bytes.
    var totalSize: Int {
        entries.values.reduce(0) { $0 + $1.size }
    }

    static let currentVersion: Int = 1

    init(version: Int = currentVersion, entries: [String: DiskCacheEntry] = [:]) {
        self.version = version
        self.entries = entries
    }
}

// MARK: - Cache Key Generator

/// Generates cache keys and file names.
public enum CacheKeyGenerator {
    /// Generates a cache key from a URLRequest.
    public static func cacheKey(for request: URLRequest) -> String {
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

    /// Generates a filename from a cache key using SHA256.
    public static func filename(for cacheKey: String) -> String {
        let data: Data = Data(cacheKey.utf8)
        let hash: String = sha256(data)
        return hash
    }

    private static func sha256(_ data: Data) -> String {
        let hash: SHA256.Digest = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
