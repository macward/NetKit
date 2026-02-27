# Caching & Retry

## Response Caching

Cache GET responses in memory:

```swift
let cache = ResponseCache(maxEntries: 100)

let client = NetworkClient(
    environment: APIEnvironment(),
    cache: cache
)

// Manually invalidate cache
await cache.invalidate(for: request)
await cache.invalidateAll()
```

## Retry Policy

Automatically retry failed requests:

```swift
// Default: retry on connection errors, timeouts, and 5xx errors
let retryPolicy = RetryPolicy(maxRetries: 3)

let client = NetworkClient(
    environment: APIEnvironment(),
    retryPolicy: retryPolicy
)
```

### Exponential Backoff

```swift
let retryPolicy = RetryPolicy(
    maxRetries: 3,
    delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0.1)
)
```

### Fixed Delay

```swift
let retryPolicy = RetryPolicy(
    maxRetries: 3,
    delay: .fixed(2.0)
)
```

### Custom Retry Logic

```swift
let retryPolicy = RetryPolicy(
    maxRetries: 3,
    shouldRetry: { error in
        switch error.kind {
        case .timeout, .noConnection:
            return true
        default:
            return false
        }
    }
)
```

## Request Deduplication

Automatically deduplicate concurrent identical requests. When multiple callers request the same resource simultaneously, only one network request is executed and the result is shared:

```swift
// By default, GET requests are deduplicated automatically
// 10 concurrent calls = 1 actual network request
async let user1 = client.request(GetUserEndpoint(id: "123"))
async let user2 = client.request(GetUserEndpoint(id: "123"))
async let user3 = client.request(GetUserEndpoint(id: "123"))

// All three get the same result from a single network call
let users = try await [user1, user2, user3]
```

### Deduplication Policies

Control deduplication behavior per endpoint:

```swift
struct UserEndpoint: Endpoint {
    var path: String { "/users" }
    var method: HTTPMethod { .get }

    // Default: .automatic (GET deduplicated, mutations not)
    var deduplicationPolicy: DeduplicationPolicy { .automatic }

    typealias Response = User
}

// Force deduplication for idempotent POST
struct IdempotentEndpoint: Endpoint {
    var path: String { "/idempotent" }
    var method: HTTPMethod { .post }
    var deduplicationPolicy: DeduplicationPolicy { .always }
    typealias Response = Result
}

// Disable deduplication for GET with side effects
struct AnalyticsEndpoint: Endpoint {
    var path: String { "/track" }
    var method: HTTPMethod { .get }
    var deduplicationPolicy: DeduplicationPolicy { .never }
    typealias Response = EmptyResponse
}
```

| Policy | Behavior |
|--------|----------|
| `.automatic` | Deduplicate GET requests only (default) |
| `.always` | Always deduplicate, even mutations |
| `.never` | Never deduplicate this endpoint |

### How It Works

- Requests are identified by URL + HTTP method + body hash
- Deduplication occurs after interceptors (auth headers included)
- Each caller decodes the response independently
- Cancelling one caller doesn't affect others
- Thread-safe using Swift actors
