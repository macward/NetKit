# Task 005: Request Deduplication

**Completed**: 2026-01-21
**Branch**: task/005-request-deduplication
**Status**: Done

## Summary

Implemented request deduplication to prevent multiple identical network calls from executing simultaneously. When multiple callers request the same resource concurrently, only one network request is executed and the result is shared among all callers.

## Changes

### Added
- `Sources/NetKit/Core/DeduplicationPolicy.swift` - Enum with `.automatic`, `.always`, and `.never` policies
- `Sources/NetKit/Core/RequestKey.swift` - Hashable struct for identifying unique requests by URL, method, and body hash
- `Sources/NetKit/Core/InFlightRequestTracker.swift` - Actor for thread-safe tracking of in-flight requests
- `Tests/NetKitTests/DeduplicationTests.swift` - Comprehensive test suite with 25+ tests

### Modified
- `Sources/NetKit/Core/Endpoint.swift` - Added `deduplicationPolicy` property with default `.automatic`
- `Sources/NetKit/Core/NetworkClient.swift` - Integrated deduplication logic with atomic check-and-register

## Files Changed
- `Sources/NetKit/Core/DeduplicationPolicy.swift` (created)
- `Sources/NetKit/Core/RequestKey.swift` (created)
- `Sources/NetKit/Core/InFlightRequestTracker.swift` (created)
- `Sources/NetKit/Core/Endpoint.swift` (modified)
- `Sources/NetKit/Core/NetworkClient.swift` (modified)
- `Tests/NetKitTests/DeduplicationTests.swift` (created)
- `tasks/005-request-deduplication.task` (modified)

## Technical Details

- **Thread Safety**: Uses Swift actors for concurrent access to shared state
- **Cancellation Isolation**: Uses `Task.detached` to prevent one caller's cancellation from affecting others
- **Race Condition Prevention**: Atomic `getOrCreate` method prevents TOCTOU issues
- **Swift 6 Compliance**: Full Swift 6 concurrency safety

## Usage

```swift
// Default: GET requests are deduplicated, mutations are not
struct UsersEndpoint: Endpoint {
    var path: String { "/users" }
    var method: HTTPMethod { .get }
    // deduplicationPolicy defaults to .automatic
}

// Force deduplication for idempotent POST
struct IdempotentPostEndpoint: Endpoint {
    var path: String { "/idempotent" }
    var method: HTTPMethod { .post }
    var deduplicationPolicy: DeduplicationPolicy { .always }
}

// Disable deduplication for GET with side effects
struct AnalyticsEndpoint: Endpoint {
    var path: String { "/track" }
    var method: HTTPMethod { .get }
    var deduplicationPolicy: DeduplicationPolicy { .never }
}
```

## Notes

- Deduplication occurs AFTER interceptors are applied (auth headers affect request identity)
- Each caller decodes the shared Data independently (minimal overhead, maximum flexibility)
- No TTL needed: entries are cleaned automatically when the Task completes
