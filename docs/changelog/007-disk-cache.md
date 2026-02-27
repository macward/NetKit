# Task 007: Disk Cache Implementation

**Completed**: 2026-01-21
**Branch**: task/007-disk-cache
**Status**: Done

## Summary
Implemented a disk-based cache system as a complement to the existing in-memory cache, featuring LZFSE compression, LRU eviction, size limits, and a hybrid cache that uses memory as L1 and disk as L2.

## Changes

### Added
- `Sources/NetKit/Cache/CacheStorage.swift` - Core types for disk cache:
  - `CacheStorageType` enum (memory, disk, hybrid)
  - `DiskCacheConfiguration` struct with configurable limits
  - `DiskCacheEntry` struct with LRU tracking via `lastAccessedAt`
  - `DiskCacheIndex` struct for persistent index management
  - `CacheKeyGenerator` with SHA256-based filename generation (using CryptoKit)

- `Sources/NetKit/Cache/DiskCache.swift` - Actor-based disk cache:
  - Thread-safe file operations via actor isolation
  - LZFSE compression for entries > 1KB
  - Configurable size limits (total and per-entry)
  - LRU eviction when size limit exceeded
  - Index backup and corruption recovery
  - Cache version file for future migrations
  - Clearing methods: by endpoint, by age, total
  - Static `create()` factory method for safe initialization

- `Sources/NetKit/Cache/HybridCache.swift` - Two-level cache:
  - Memory cache as L1 (hot data, fast access)
  - Disk cache as L2 (persistent, larger capacity)
  - Automatic promotion of disk hits to memory
  - Coordinated invalidation across both layers
  - Static `create()` factory method for safe initialization

- `Tests/NetKitTests/DiskCacheTests.swift` - Comprehensive tests (253 tests):
  - Configuration and entry struct tests
  - Cache key generation tests
  - Store/retrieve/invalidate tests
  - Expiration and TTL tests
  - LRU eviction tests
  - Compression verification tests
  - Size limit enforcement tests
  - Hybrid cache integration tests
  - Factory method tests

### Modified
- `Sources/NetKit/Cache/ResponseCache.swift` - Now uses shared `CacheKeyGenerator`
- `tasks/007-disk-cache.task` - Marked as done with all steps completed

## Technical Details

### Architecture
```
NetworkClient
     │
     ▼
┌─────────────────────┐
│   ResponseCache     │ (existing memory cache)
│   HybridCache       │ (new - memory + disk)
│   DiskCache         │ (new - disk only)
└─────────────────────┘
```

### File Structure on Disk
```
Caches/com.netkit.cache/
├── index.json      # Entry metadata with LRU timestamps
├── entries/        # Cached data files (SHA256 named)
│   └── {hash}.data
└── version         # Cache version for migrations
```

### Configuration Defaults
| Setting | Default Value |
|---------|---------------|
| Max cache size | 50 MB |
| Max entry size | 5 MB |
| Compression threshold | 1 KB |
| File protection | Off |

### Key Features
- **Thread Safety**: All file operations isolated in actor
- **Compression**: LZFSE for data > 1KB (Apple recommended)
- **LRU Eviction**: Based on `lastAccessedAt` timestamp
- **Corruption Recovery**: Index backup + automatic recovery
- **HTTP Headers Integration**: Uses existing `CacheMetadata` (Codable)
- **Factory Methods**: `DiskCache.create()` and `HybridCache.create()` for safe initialization
- **Modern Crypto**: Uses CryptoKit (iOS 13+) instead of CommonCrypto for SHA256

## Files Changed
- `Sources/NetKit/Cache/CacheStorage.swift` (created)
- `Sources/NetKit/Cache/DiskCache.swift` (created)
- `Sources/NetKit/Cache/HybridCache.swift` (created)
- `Sources/NetKit/Cache/ResponseCache.swift` (modified - uses shared CacheKeyGenerator)
- `Tests/NetKitTests/DiskCacheTests.swift` (created)
- `tasks/007-disk-cache.task` (modified)

## Notes
- Uses iOS Caches directory so system can clean if needed
- Optional file protection via `NSFileProtectionComplete`
- All metadata types already Codable from HTTP cache headers task
- Version file enables future migrations without data loss
