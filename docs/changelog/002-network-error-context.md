# Task 002: Enhanced NetworkError with Context

**Completed**: 2026-01-21
**Branch**: task/002-network-error-context
**Status**: Done

## Summary

Refactored `NetworkError` from a simple enum to a rich struct with full request/response context, improving debugging and observability. The new design includes request snapshots, response snapshots, error kinds, timestamp, retry attempt tracking, and automatic sanitization of sensitive headers.

## Changes

### Added

- `RequestSnapshot` struct: Captures URL, HTTP method, sanitized headers, and body size
- `ResponseSnapshot` struct: Captures status code, sanitized headers, body preview (512 bytes max), and body size
- `ErrorKind` enum: Typed error categories with specific cases for common HTTP errors
  - New cases: `rateLimited` (429), `badGateway` (502), `serviceUnavailable` (503), `gatewayTimeout` (504), `clientError(statusCode:)`
- Helper properties on `ErrorKind`: `isServerError`, `isClientError`, `isRetryable`, `statusCode`
- Header sanitization for sensitive headers: `Authorization`, `X-API-Key`, `Cookie`, etc.
- `LocalizedError` conformance with `errorDescription`, `failureReason`, `recoverySuggestion`
- `CustomDebugStringConvertible` for better debug output
- Factory methods for common error types: `.timeout()`, `.notFound()`, `.unauthorized()`, etc.

### Modified

- `NetworkError`: Changed from enum to struct with `kind`, `request`, `response`, `underlyingError`, `timestamp`, `retryAttempt` fields
- `NetworkClient.swift`: Updated all throw sites to include request/response context
- `LongPollingStream.swift`: Updated error handling to use `error.kind` pattern matching
- `RetryPolicy.swift`: Updated default retry logic to check `error.kind` and include new retryable error types
- `URLRequest+Extensions.swift`: Updated to use new factory methods
- Tests: Updated to use new API (`error.kind` instead of direct pattern matching)

## Files Changed

- `Sources/NetKit/Models/NetworkError.swift` (rewritten)
- `Sources/NetKit/Core/NetworkClient.swift` (modified)
- `Sources/NetKit/LongPolling/LongPollingStream.swift` (modified)
- `Sources/NetKit/Retry/RetryPolicy.swift` (modified)
- `Sources/NetKit/Extensions/URLRequest+Extensions.swift` (modified)
- `Tests/NetKitTests/NetKitTests.swift` (modified)

## Breaking Changes

This is a **major breaking change**. Code that previously matched on `NetworkError` cases directly must now access the `.kind` property:

**Before:**
```swift
catch let error as NetworkError {
    switch error {
    case .timeout: // handle
    case .unauthorized: // handle
    }
}
```

**After:**
```swift
catch let error as NetworkError {
    switch error.kind {
    case .timeout: // handle
    case .unauthorized: // handle
    }

    // Now with access to rich context:
    // - error.request?.url
    // - error.response?.statusCode
    // - error.underlyingError
    // - error.retryAttempt
}
```

## API Examples

```swift
// Creating errors with context
let error = NetworkError.timeout(
    request: RequestSnapshot(request: urlRequest),
    underlyingError: urlError
)

// Accessing error details
print(error.kind)                    // .timeout
print(error.request?.url)            // URL that timed out
print(error.errorDescription)        // "The request timed out."
print(error.recoverySuggestion)      // "The server may be slow. Please try again."

// Checking error type
if error.kind.isRetryable {
    // Retry the request
}

if let statusCode = error.kind.statusCode {
    print("HTTP \(statusCode)")
}

// Headers are automatically sanitized
let snapshot = RequestSnapshot(
    url: url,
    method: "GET",
    headers: ["Authorization": "Bearer secret"]
)
print(snapshot.headers["Authorization"]) // "[REDACTED]"
```

## Notes

- The `timestamp` field is intentionally excluded from Equatable comparison
- Body preview is truncated at valid UTF-8 boundaries to prevent encoding issues
- Sensitive headers are automatically redacted in snapshots for security
