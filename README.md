# NetKit

A simple, secure, and reusable networking layer for Swift.

## Features

- Type-safe API requests with `Endpoint` protocol
- Upload & download with real-time progress tracking
- Multipart form data support
- Long polling for real-time updates
- Automatic retry with exponential backoff
- Response caching with HTTP header support
- Request deduplication for concurrent identical requests
- Request/response interceptors (auth, logging)
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

## Quick Start

```swift
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

// 3. Make requests
let client = NetworkClient(environment: APIEnvironment())
let user = try await client.request(GetUserEndpoint(id: "123"))
```

## Documentation

For detailed documentation, see the [docs](docs/) folder:

| Guide | Description |
|-------|-------------|
| [Getting Started](docs/getting-started.md) | Installation, Quick Start, Core Concepts |
| [Endpoints](docs/endpoints.md) | Common Use Cases, Fluent API |
| [Authentication](docs/authentication.md) | Auth Interceptors, Token Refresh |
| [Caching & Retry](docs/caching-retry.md) | Response Caching, Retry Policy, Deduplication |
| [Logging](docs/logging.md) | Logging, Sensitive Data Sanitization |
| [Long Polling](docs/long-polling.md) | Real-time Updates with Long Polling |
| [Transfers](docs/transfers.md) | Upload & Download with Progress |
| [Testing](docs/testing.md) | MockNetworkClient, Dependency Injection |
| [Configuration](docs/configuration.md) | Environments, JSON Encoding/Decoding |
| [Examples](docs/examples.md) | Full Example, Error Handling Patterns |

## License

MIT License
