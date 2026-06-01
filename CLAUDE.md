# CLAUDE.md

vibe: netkit

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Search & Analysis Exclusions

When searching or analyzing **code**, focus on `Sources/` and `Tests/`.

- `docs/` - Not source code. Skip it for code-structure queries, but DO consult it as reference for API behavior, usage, and design (auth, caching, certificate pinning, transfers, testing).

## Project Overview

NetKit is a Swift networking library for iOS 18+ and macOS 15+, built with Swift 6.2 and no external dependencies. It provides a type-safe, protocol-oriented approach to API communication with built-in support for authentication, caching, retries, request deduplication, uploads/downloads with progress, certificate pinning, metrics, and long polling.

## Build & Test Commands

**ALWAYS use xcodebuild, never `swift build` or `swift test`.**

```bash
# Build
xcodebuild -scheme NetKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Run tests
xcodebuild -scheme NetKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Lint
swiftlint
```

## Architecture

```
Sources/NetKit/
├── Core/           # NetworkClient, NetworkClientProtocol, Endpoint, RequestBuilder, UploadResult/DownloadResult
├── Models/         # HTTPMethod, NetworkError, NetworkEnvironment, EmptyResponse, DeduplicationPolicy
├── Interceptors/   # Interceptor protocol, AuthInterceptor, TokenRefreshCoordinator, LoggingInterceptor
├── Cache/          # ResponseCache (memory + disk), CachePolicy, Cache-Control/ETag parsing
├── Retry/          # RetryPolicy with delay strategies
├── LongPolling/    # LongPollingEndpoint, LongPollingStream, LongPollingConfiguration
├── Progress/       # TransferProgress, TransferProgressStream, MultipartFormData
├── Security/       # SecurityPolicy, PinningSessionFactory, CertificatePinningDelegate (cert pinning)
├── Metrics/        # MetricsCollector, NetworkRequestMetrics
├── Mock/           # MockNetworkClient for testing
└── Extensions/     # URLRequest extensions
```

### Core Flow

`NetworkClient.request(Endpoint)` → Apply interceptors → Check cache (GET) → Deduplicate concurrent identical requests → Execute with retry logic → Cache GET responses → Decode response

### Key Protocols

- **Endpoint**: Defines API endpoints (path, method, headers, queryParameters, body, Response type; plus cacheTTL, cachePolicy, deduplicationPolicy)
- **LongPollingEndpoint**: Extends Endpoint with polling behavior (pollingTimeout, retryInterval, shouldContinuePolling)
- **NetworkEnvironment**: Configuration (baseURL, defaultHeaders, timeout)
- **Interceptor**: Request/response interception (auth, logging, custom)
- **NetworkClientProtocol**: Enables dependency injection and MockNetworkClient for tests

## Swift Rules

### Code Style

- Use `guard` for early exit
- Explicit type annotations: `let value: String = "text"`
- Optional shorthand: `if let value { }` not `if let value = value { }`
- Mark access control explicitly (`public`, `internal`, `private`)
- Use `// MARK: -` to separate sections
- Separate protocol conformances into extensions

### Async/Await

- ALWAYS use async/await, NEVER completion handlers
- NEVER use `DispatchQueue.main.async` — use `MainActor` instead
- NEVER use `try!` in async code
- Use `.task` modifier for async work in Views
- Use `AsyncStream` for continuous data streams

### Testing

- Use Swift Testing (`@Test`), not XCTest
- Test names: `subjectAction` or `subjectActionCondition`
- ALWAYS add descriptive string to `@Test` macro: `@Test("Description")`
- Use protocols for dependencies, create manual mocks (no mocking libraries)
- For packages: test public API thoroughly, test internal logic only if complex

### Package Structure

- Organize by responsibility (Client/, Cache/, Interceptors/), not by type
- Use `public`/`internal` access control, not separate folders
- Tests mirror source structure
- Platform-specific code uses `#if os()` inline
