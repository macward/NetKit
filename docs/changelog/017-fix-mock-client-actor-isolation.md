# Task 017: Fix MockNetworkClient Actor Isolation Violation

**Completed**: 2026-01-22
**Branch**: task/017-fix-mock-client-actor-isolation
**Status**: Done

## Summary
Fixed actor isolation violations in `MockNetworkClient` where `nonisolated` upload/download methods created Tasks that accessed isolated actor state (`stubs`, `callCounts`). This violated Swift 6 actor isolation guarantees and could cause data races in test code.

## Changes

### Modified
- `Sources/NetKit/Core/NetworkClientProtocol.swift` - Made `upload(file:to:)`, `upload(formData:to:)`, and `download(from:to:)` methods `async` to allow proper actor conformance
- `Sources/NetKit/Core/NetworkClient.swift` - Added `async` keyword to upload/download method implementations
- `Sources/NetKit/Mock/MockNetworkClient.swift` - Removed `nonisolated` keyword from upload/download methods, added `async` keyword, added explicit `self.` for actor-isolated calls
- `Tests/NetKitTests/ProgressTests.swift` - Added `await` to all upload/download test calls, added new `MockNetworkClient Concurrent Access Tests` suite

### Breaking
- `NetworkClientProtocol.upload(file:to:)` is now `async`
- `NetworkClientProtocol.upload(formData:to:)` is now `async`
- `NetworkClientProtocol.download(from:to:)` is now `async`

Callers must now use `await` when calling these methods. This is a necessary change for Swift 6 concurrency compliance.

## Files Changed
- `Sources/NetKit/Core/NetworkClientProtocol.swift` (modified)
- `Sources/NetKit/Core/NetworkClient.swift` (modified)
- `Sources/NetKit/Mock/MockNetworkClient.swift` (modified)
- `Tests/NetKitTests/ProgressTests.swift` (modified)
- `tasks/017-fix-mock-client-actor-isolation.task` (modified)

## Notes
The original design had `nonisolated` methods that returned `UploadResult`/`DownloadResult` structs containing `Task` objects. The Tasks inside would then access actor-isolated state, which violates Swift 6 actor isolation rules.

The solution was to make the protocol methods `async`, which allows the `MockNetworkClient` actor to properly conform without `nonisolated`. When the methods are `async`, callers must `await` them, which properly crosses the actor isolation boundary before the method body executes.

New concurrent access tests were added to verify thread safety:
- `Concurrent uploads are thread-safe` - 50 concurrent uploads
- `Concurrent downloads are thread-safe` - 50 concurrent downloads
- `Concurrent mixed operations are thread-safe` - 25 uploads + 25 downloads concurrently
