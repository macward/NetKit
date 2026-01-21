# NetKit Documentation

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
- **SSL/TLS Certificate Pinning** for MITM protection
- Sensitive data sanitization in logs
- Full async/await support with Swift 6 concurrency

## Requirements

- iOS 18.0+ / macOS 15.0+
- Swift 6.0+
- No external dependencies

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting Started](getting-started.md) | Installation, Quick Start, Core Concepts |
| [Endpoints](endpoints.md) | Common Use Cases, Fluent API |
| [Authentication](authentication.md) | Auth Interceptors, Token Refresh |
| [Caching & Retry](caching-retry.md) | Response Caching, Retry Policy, Deduplication |
| [Logging](logging.md) | Logging, Sensitive Data Sanitization |
| [Long Polling](long-polling.md) | Real-time Updates with Long Polling |
| [Transfers](transfers.md) | Upload & Download with Progress |
| [Certificate Pinning](certificate-pinning.md) | SSL/TLS Security, MITM Protection |
| [Testing](testing.md) | MockNetworkClient, Dependency Injection |
| [Configuration](configuration.md) | Environments, JSON Encoding/Decoding |
| [Examples](examples.md) | Full Example, Error Handling Patterns |

## Quick Installation

Add NetKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-username/NetKit.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Package Dependencies → Enter the repository URL.

## License

MIT License
