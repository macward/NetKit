# NetKit

**The SwiftUI data layer Swift never had — `@Resource`, in the spirit of TanStack Query. Zero dependencies.**

On the web, reading server state is a solved problem: you reach for TanStack Query or SWR and
get a shared cache, request deduplication, and revalidation for free. In SwiftUI you rebuild it
by hand in every app — `@State` for value/loading/error, `.task` to kick it off, your own
caching, your own refresh-on-foreground. NetKit brings that data layer to SwiftUI natively:

```swift
struct ProfileView: View {
    @Resource(GetUser(id: "123")) var user

    var body: some View {
        if let user = user.value {
            Text(user.name)
        } else if user.isLoading {
            ProgressView()
        } else if let error = user.error {
            Text(error.localizedDescription)
        }
    }
}
```

One property declares the data a view needs and returns observable loading/value/error state,
a cache shared by key, request deduplication, and stale-while-revalidate — no manual `@State` +
`.task` plumbing.

Under it sits **a full networking layer** — the transport `@Resource` reads through, and a
capable HTTP client in its own right: type-safe `Endpoint`s, interceptors, caching, retries,
uploads/downloads with progress, long polling, and certificate pinning, all `async`/`await` on
Swift 6 concurrency. Use the data layer for your screens, drop down to the networking layer
when you need raw control — same package, same auth interceptors, nothing else to install.

## Why NetKit?

Every networking library in Swift — URLSession, Alamofire, Get — **stops at the transport**.
They hand you decoded bytes and leave the hard part to you: sharing reads across screens,
deduping concurrent requests, keeping data fresh, showing the old value while the new one loads.
On the web that layer has a name (TanStack Query, SWR); in Swift you hand-roll it in every app.
NetKit is the package that ships it — all the way from the socket to the view.

|                                      | NetKit | URLSession | Alamofire | Get |
|--------------------------------------|:------:|:----------:|:---------:|:---:|
| **SwiftUI data layer (`@Resource`)** | **✅** |    ❌      |    ❌     | ❌  |
| **Observable query cache + SWR**     | **✅** |    ❌      |    ❌     | ❌  |
| **Request dedup across views**       | **✅** |    ❌      |    ❌     | ❌  |
| Type-safe `Endpoint`s                |   ✅   |     ❌     |     ❌    | ✅  |
| Native `async`/`await` + Swift 6     |   ✅   |     ✅     |     ✅    | ✅  |
| Interceptors / middleware            |   ✅   |     ❌     |     ✅    | ✅  |
| HTTP response caching                |   ✅   |  URLCache  |     ✅    | ❌  |
| Automatic retries                    |   ✅   |     ❌     |     ✅    | ✅  |
| Certificate pinning                  |   ✅   |   manual   |     ✅    | ❌  |
| Upload/download progress             |   ✅   |   manual   |     ✅    | manual |
| External dependencies                | **0**  |   **0**    |   **0**   | **0** |

The bottom rows are table stakes — NetKit holds its own as a transport, dependency-free. The
top three are why it exists: the observable query cache, dedup, and stale-while-revalidate you'd
otherwise reimplement on top of any of the others.

## Features

### Data layer (`@Resource`) — the headline

- Declarative, observable resources for SwiftUI — no manual `@State` + `.task` plumbing
- Shared query cache keyed by `QueryKey`, with query-level deduplication
- Stale-while-revalidate: revalidates on foreground / reappear while keeping the previous value on screen
- Garbage collection by observer count and per-session auth isolation
- Invalidation and optimistic writes via `QueryClient`

### Networking layer — the transport it reads through

- Type-safe API requests with `Endpoint` protocol
- Declarative endpoint macros (`@GET`/`@POST`/…) via the optional `NetKitMacros` package
- Upload & download with real-time progress tracking
- Multipart form data support
- Long polling for real-time updates
- Automatic retry with exponential backoff
- Response caching with HTTP header support
- Request deduplication for concurrent identical requests
- Request/response interceptors (auth, logging)
- **SSL/TLS Certificate Pinning** for MITM protection
- Sensitive data sanitization in logs
- Full async/await support with Swift 6 concurrency

## Requirements

- iOS 18.0+ / macOS 15.0+
- Swift 6.0+
- No external dependencies

## Installation

Add NetKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-username/NetKit.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Package Dependencies → Enter the repository URL.

The core package is dependency-free. To declare endpoints with macros instead of hand-written
structs, also add the optional `NetKitMacros` package — see [Endpoint Macros](docs/macros.md).
Consumers who stick with the manual `Endpoint` model pull in nothing extra.

## Quick Start

The data layer is the fast path for any screen that *reads* server state. Define an endpoint
once, inject a `QueryClient` near the root of your app, and declare the resource each view needs.

```swift
import SwiftUI
import NetKit

// 1. Define your environment
struct APIEnvironment: NetworkEnvironment {
    var baseURL: URL { URL(string: "https://api.example.com")! }
    var defaultHeaders: [String: String] { ["Content-Type": "application/json"] }
    var timeout: TimeInterval { 30 }
}

// 2. Define your endpoint
struct GetUserEndpoint: Endpoint {
    let id: String
    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }
    typealias Response = User
}

// 3. Inject a QueryClient once, near the root
@main
struct MyApp: App {
    private let client = NetworkClient(environment: APIEnvironment())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .queryClient(QueryClient(network: client))
        }
    }
}

// 4. Declare the resource a view needs — caching, dedup, and SWR come for free
struct ProfileView: View {
    @Resource(GetUserEndpoint(id: "123")) var user

    var body: some View {
        if let user = user.value {
            Text(user.name)
        } else if user.isLoading {
            ProgressView()
        } else if let error = user.error {
            Text(error.localizedDescription)
        }
    }
}
```

You get shared caching by key, request deduplication, and stale-while-revalidate out of the
box. See the [Data Layer](docs/data-layer.md) guide for invalidation, optimistic writes,
freshness, and garbage collection.

## Dropping down to the networking layer

The data layer reads through a `NetworkClient` — and that client is a full HTTP client you can
use directly whenever you need raw control (mutations, one-off calls, uploads, anything outside
a view):

```swift
let client = NetworkClient(environment: APIEnvironment())
let user = try await client.request(GetUserEndpoint(id: "123"))
```

Same endpoints, same interceptors, same auth — the data layer and the imperative API never drift
apart because they share the same transport.

## Interceptors

Interceptors are a core architectural pattern in NetKit that enables request/response modification through a clean, composable pipeline. This design is inspired by the **Chain of Responsibility** pattern and middleware systems found in frameworks like OkHttp (Android) and Alamofire.

### Why Interceptors?

Instead of cluttering the main networking logic with cross-cutting concerns (authentication, logging, metrics), interceptors provide:

- **Separation of concerns**: Each interceptor handles one responsibility
- **Composability**: Stack multiple interceptors in any order
- **Testability**: Test interceptors in isolation
- **Reusability**: Share interceptors across different clients

### How They Work

```
Request Flow:
┌─────────────────────────────────────────────────────────────────┐
│  Your Code → Interceptor 1 → Interceptor 2 → ... → URLSession  │
└─────────────────────────────────────────────────────────────────┘

Response Flow:
┌─────────────────────────────────────────────────────────────────┐
│  URLSession → Interceptor N → ... → Interceptor 1 → Your Code  │
└─────────────────────────────────────────────────────────────────┘
```

Requests pass through interceptors in order; responses pass through in **reverse order**. This allows interceptors like logging to see both the final request and the original response.

### Built-in Interceptors

**AuthInterceptor** — Injects authentication tokens and handles 401 responses:

```swift
let auth = AuthInterceptor(
    tokenProvider: { await tokenStore.accessToken },
    onUnauthorized: { await tokenStore.refresh() }
)
```

**LoggingInterceptor** — Logs requests/responses with automatic PII sanitization:

```swift
let logging = LoggingInterceptor(
    level: .verbose,
    sanitization: .default  // Redacts Authorization headers, passwords, etc.
)
```

### Creating Custom Interceptors

Implement the `Interceptor` protocol to create your own:

```swift
struct MetricsInterceptor: Interceptor {
    func intercept(request: URLRequest) async throws -> URLRequest {
        // Add custom headers, track timing, etc.
        var modified = request
        modified.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return modified
    }

    func intercept(response: HTTPURLResponse, data: Data) async throws -> Data {
        // Log metrics, transform data, etc.
        Analytics.track("api_response", properties: [
            "status": response.statusCode,
            "url": response.url?.path ?? ""
        ])
        return data
    }
}
```

### Using Interceptors

Pass interceptors when creating the client. Order matters—first interceptor runs first on requests:

```swift
let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [
        LoggingInterceptor(level: .verbose),  // Logs first, sees final response last
        AuthInterceptor(tokenProvider: { token }),  // Adds auth after logging
        MetricsInterceptor()  // Runs last on request, first on response
    ]
)
```

## Documentation

For detailed documentation, see the [docs](docs/) folder:

| Guide | Description |
|-------|-------------|
| [Data Layer](docs/data-layer.md) | **`@Resource`, `QueryClient` injection, invalidation, optimistic writes, revalidation & GC** |
| [Getting Started](docs/getting-started.md) | Installation, Quick Start, Core Concepts |
| [Endpoints](docs/endpoints.md) | Common Use Cases, Fluent API |
| [Endpoint Macros](docs/macros.md) | Declarative `@GET`/`@POST` endpoints, before/after, opt-in setup |
| [Authentication](docs/authentication.md) | Auth Interceptors, Token Refresh |
| [Caching & Retry](docs/caching-retry.md) | Response Caching, Retry Policy, Deduplication |
| [Logging](docs/logging.md) | Logging, Sensitive Data Sanitization |
| [Long Polling](docs/long-polling.md) | Real-time Updates with Long Polling |
| [Transfers](docs/transfers.md) | Upload & Download with Progress |
| [Certificate Pinning](docs/certificate-pinning.md) | SSL/TLS Security, MITM Protection |
| [Testing](docs/testing.md) | MockNetworkClient, Dependency Injection |
| [Configuration](docs/configuration.md) | Environments, JSON Encoding/Decoding |
| [Examples](docs/examples.md) | Full Example, Error Handling Patterns |

## License

MIT License
