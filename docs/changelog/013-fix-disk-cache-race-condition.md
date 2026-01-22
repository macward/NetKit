# Task 013: Fix DiskCache Index Save Race Condition

**Completed**: 2026-01-21
**Branch**: task/013-fix-disk-cache-race-condition
**Status**: Done

## Summary

Fixed a critical race condition in DiskCache where multiple concurrent `saveIndexAsync()` calls could write stale snapshots, causing lost cache entries under high load. Implemented a serialized index writer with write coalescing using Swift actors.

## Changes

### Added
- `IndexWriter` class - A Sendable wrapper that provides thread-safe access to index writing
- `IndexWriteCoordinator` actor - Handles serialized writes with 100ms coalescing interval
- `flushIndex()` method on DiskCache - Forces immediate write, useful for testing and graceful shutdown
- 6 new concurrency tests in `DiskCacheConcurrencyTests` suite:
  - Concurrent stores do not lose entries
  - Concurrent store and retrieve operations are consistent
  - Concurrent store and invalidate operations are safe
  - Rapid sequential writes are coalesced correctly
  - High-frequency operations stress test
  - Index persistence survives reload after concurrent operations

### Modified
- `DiskCache.swift` - Refactored `saveIndexAsync()` to use the new `IndexWriter`
- `DiskCacheTests.swift` - Added comprehensive concurrency test suite

## Technical Details

The solution uses a two-tier design:
1. `IndexWriter` (Sendable class) - Provides a fire-and-forget API via `scheduleWrite()` that can be called from synchronous contexts
2. `IndexWriteCoordinator` (actor) - Serializes all write operations and coalesces rapid writes within a 100ms window

Key features:
- Write coalescing: Multiple rapid writes result in a single disk I/O operation
- Task cancellation handling: Properly checks for cancellation after sleep
- Flush support: Allows forcing immediate writes for testing or app termination
- Maintains existing backup-before-write strategy for crash recovery

## Files Changed
- `Sources/NetKit/Cache/DiskCache.swift` (modified)
- `Tests/NetKitTests/DiskCacheTests.swift` (modified)

## Notes
- The coalesce interval (100ms) provides a good balance between write batching and data freshness
- The `flushIndex()` method should be called before app termination to ensure all pending writes are persisted
- All 288 existing tests pass with the new implementation
