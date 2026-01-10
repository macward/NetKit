# NetKit

A simple, secure, and reusable networking layer for Swift.

## Requirements

- iOS 18.0+ / macOS 15.0+
- Swift 6.0+
- No external dependencies

## Installation

### Swift Package Manager

Add NetKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-username/NetKit.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Package Dependencies → Enter the repository URL.

## Quick Start

### 1. Define your Environment

```swift
import NetKit

struct APIEnvironment: NetworkEnvironment {
    var baseURL: URL { URL(string: "https://api.example.com")! }
    var defaultHeaders: [String: String] {
        ["Content-Type": "application/json"]
    }
    var timeout: TimeInterval { 30 }
}
```

### 2. Define your Endpoints

```swift
struct GetUserEndpoint: Endpoint {
    let id: String

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }

    typealias Response = User
}

struct User: Codable, Sendable {
    let id: String
    let name: String
    let email: String
}
```

### 3. Create the Client and Make Requests

```swift
let client = NetworkClient(environment: APIEnvironment())

// Simple request
let user = try await client.request(GetUserEndpoint(id: "123"))
print(user.name)
```

## Core Concepts

### Endpoint Protocol

Every API endpoint is defined as a struct conforming to `Endpoint`:

```swift
public protocol Endpoint: Sendable {
    associatedtype Response: Decodable & Sendable

    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String] { get }        // Optional, defaults to [:]
    var queryParameters: [String: String] { get } // Optional, defaults to [:]
    var body: (any Encodable & Sendable)? { get } // Optional, defaults to nil
}
```

### HTTP Methods

```swift
public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}
```

### Network Errors

```swift
public enum NetworkError: Error {
    case invalidURL
    case noConnection
    case timeout
    case unauthorized      // 401
    case forbidden         // 403
    case notFound          // 404
    case serverError(statusCode: Int)  // 5xx
    case decodingError(Error)
    case encodingError(Error)
    case unknown(Error)
}
```

## Common Use Cases

### GET Request

```swift
struct GetUsersEndpoint: Endpoint {
    var path: String { "/users" }
    var method: HTTPMethod { .get }

    typealias Response = [User]
}

let users = try await client.request(GetUsersEndpoint())
```

### GET with Query Parameters

```swift
struct SearchUsersEndpoint: Endpoint {
    let query: String
    let page: Int

    var path: String { "/users/search" }
    var method: HTTPMethod { .get }
    var queryParameters: [String: String] {
        ["q": query, "page": String(page)]
    }

    typealias Response = SearchResults
}

let results = try await client.request(SearchUsersEndpoint(query: "john", page: 1))
```

### POST with Body

```swift
struct CreateUserEndpoint: Endpoint {
    let name: String
    let email: String

    var path: String { "/users" }
    var method: HTTPMethod { .post }
    var body: (any Encodable & Sendable)? {
        CreateUserRequest(name: name, email: email)
    }

    typealias Response = User
}

struct CreateUserRequest: Encodable, Sendable {
    let name: String
    let email: String
}

let newUser = try await client.request(CreateUserEndpoint(name: "John", email: "john@example.com"))
```

### PUT/PATCH Request

```swift
struct UpdateUserEndpoint: Endpoint {
    let id: String
    let name: String

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .patch }
    var body: (any Encodable & Sendable)? {
        ["name": name]
    }

    typealias Response = User
}
```

### DELETE Request (Empty Response)

```swift
struct DeleteUserEndpoint: Endpoint {
    let id: String

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .delete }

    typealias Response = EmptyResponse
}

try await client.request(DeleteUserEndpoint(id: "123"))
```

### Custom Headers per Endpoint

```swift
struct UploadEndpoint: Endpoint {
    var path: String { "/upload" }
    var method: HTTPMethod { .post }
    var headers: [String: String] {
        ["X-Upload-Token": "abc123"]
    }

    typealias Response = UploadResult
}
```

## Fluent API

For per-request customization, use the fluent builder:

```swift
let user = try await client
    .request(GetUserEndpoint(id: "123"))
    .timeout(60)
    .header("X-Request-ID", UUID().uuidString)
    .headers(["X-Custom": "value"])
    .send()
```

## Authentication

### Bearer Token Authentication

```swift
let authInterceptor = AuthInterceptor(
    tokenProvider: {
        // Return your token from secure storage
        await TokenManager.shared.accessToken
    }
)

let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [authInterceptor]
)
```

### API Key Authentication

```swift
let apiKeyInterceptor = AuthInterceptor(
    headerName: "X-API-Key",
    tokenPrefix: nil,  // No prefix
    tokenProvider: { "your-api-key" }
)
```

### Token Refresh on 401

```swift
let authInterceptor = AuthInterceptor(
    tokenProvider: { await TokenManager.shared.accessToken },
    onUnauthorized: {
        // Refresh token or logout
        try await TokenManager.shared.refreshToken()
    }
)
```

## Retry Policy

Automatically retry failed requests:

```swift
// Default: retry on connection errors, timeouts, and 5xx errors
let retryPolicy = RetryPolicy(maxRetries: 3)

// With exponential backoff
let retryPolicy = RetryPolicy(
    maxRetries: 3,
    delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0.1)
)

// Fixed delay
let retryPolicy = RetryPolicy(
    maxRetries: 3,
    delay: .fixed(2.0)
)

// Custom retry logic
let retryPolicy = RetryPolicy(
    maxRetries: 3,
    shouldRetry: { error in
        switch error {
        case .timeout, .noConnection:
            return true
        default:
            return false
        }
    }
)

let client = NetworkClient(
    environment: APIEnvironment(),
    retryPolicy: retryPolicy
)
```

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

## Logging

Log requests and responses:

```swift
let loggingInterceptor = LoggingInterceptor(level: .verbose)
// Levels: .none, .minimal, .verbose

let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [loggingInterceptor]
)
```

## Custom Interceptors

Create your own interceptors:

```swift
struct CustomInterceptor: Interceptor {
    func intercept(request: URLRequest) async throws -> URLRequest {
        var modified = request
        modified.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return modified
    }

    func intercept(response: HTTPURLResponse, data: Data) async throws -> Data {
        print("Response status: \(response.statusCode)")
        return data
    }
}
```

## Multiple Environments

```swift
enum AppEnvironment: NetworkEnvironment {
    case development
    case staging
    case production

    var baseURL: URL {
        switch self {
        case .development: URL(string: "https://dev-api.example.com")!
        case .staging: URL(string: "https://staging-api.example.com")!
        case .production: URL(string: "https://api.example.com")!
        }
    }

    var defaultHeaders: [String: String] {
        ["Content-Type": "application/json"]
    }

    var timeout: TimeInterval { 30 }
}

let client = NetworkClient(environment: AppEnvironment.production)
```

## Custom JSON Encoding/Decoding

```swift
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
decoder.keyDecodingStrategy = .convertFromSnakeCase

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.keyEncodingStrategy = .convertToSnakeCase

let client = NetworkClient(
    environment: APIEnvironment(),
    decoder: decoder,
    encoder: encoder
)
```

## Testing with MockNetworkClient

NetKit includes a mock client for unit testing:

```swift
import XCTest
@testable import NetKit

final class UserServiceTests: XCTestCase {
    var mockClient: MockNetworkClient!
    var userService: UserService!

    override func setUp() async throws {
        mockClient = MockNetworkClient()
        userService = UserService(client: mockClient)
    }

    func testGetUser() async throws {
        // Stub the response
        await mockClient.stub(GetUserEndpoint.self) { endpoint in
            User(id: endpoint.id, name: "John", email: "john@example.com")
        }

        // Test your service
        let user = try await userService.getUser(id: "123")

        // Verify
        XCTAssertEqual(user.name, "John")
        let callCount = await mockClient.callCount(for: GetUserEndpoint.self)
        XCTAssertEqual(callCount, 1)
    }

    func testGetUserError() async throws {
        // Stub an error
        await mockClient.stubError(GetUserEndpoint.self, error: .notFound)

        // Test error handling
        do {
            _ = try await userService.getUser(id: "invalid")
            XCTFail("Expected error")
        } catch let error as NetworkError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testNetworkDelay() async throws {
        // Stub with delay
        await mockClient.stub(GetUserEndpoint.self, delay: 0.5) { _ in
            User(id: "1", name: "John", email: "john@example.com")
        }

        let start = Date()
        _ = try await userService.getUser(id: "1")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.5)
    }
}
```

### MockNetworkClient API

```swift
// Stub success response
await mockClient.stub(EndpointType.self) { endpoint in
    // Return response based on endpoint properties
}

// Stub with delay
await mockClient.stub(EndpointType.self, delay: 1.0) { endpoint in
    // Return response
}

// Stub error
await mockClient.stubError(EndpointType.self, error: .notFound)

// Check call count
let count = await mockClient.callCount(for: EndpointType.self)

// Check if called
let wasCalled = await mockClient.wasCalled(EndpointType.self)

// Get called endpoints
let endpoints = await mockClient.calledEndpoints(of: EndpointType.self)

// Reset all stubs and history
await mockClient.reset()
```

## Dependency Injection

Use the `NetworkClientProtocol` for dependency injection:

```swift
class UserService {
    private let client: NetworkClientProtocol

    init(client: NetworkClientProtocol) {
        self.client = client
    }

    func getUser(id: String) async throws -> User {
        try await client.request(GetUserEndpoint(id: id))
    }
}

// Production
let service = UserService(client: NetworkClient(environment: APIEnvironment()))

// Testing
let service = UserService(client: MockNetworkClient())
```

## Error Handling

```swift
do {
    let user = try await client.request(GetUserEndpoint(id: "123"))
} catch NetworkError.unauthorized {
    // Handle 401 - redirect to login
} catch NetworkError.notFound {
    // Handle 404 - show not found UI
} catch NetworkError.noConnection {
    // Handle offline - show retry option
} catch NetworkError.timeout {
    // Handle timeout - suggest retry
} catch NetworkError.serverError(let statusCode) {
    // Handle 5xx errors
    print("Server error: \(statusCode)")
} catch NetworkError.decodingError(let error) {
    // Handle JSON parsing errors
    print("Failed to decode: \(error)")
} catch {
    // Handle other errors
    print("Unknown error: \(error)")
}
```

## Full Example

```swift
import NetKit

// MARK: - Environment

struct APIEnvironment: NetworkEnvironment {
    var baseURL: URL { URL(string: "https://api.example.com/v1")! }
    var defaultHeaders: [String: String] {
        ["Content-Type": "application/json", "Accept": "application/json"]
    }
    var timeout: TimeInterval { 30 }
}

// MARK: - Models

struct User: Codable, Sendable {
    let id: String
    let name: String
    let email: String
}

// MARK: - Endpoints

struct GetUserEndpoint: Endpoint {
    let id: String
    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }
    typealias Response = User
}

struct CreateUserEndpoint: Endpoint {
    let name: String
    let email: String
    var path: String { "/users" }
    var method: HTTPMethod { .post }
    var body: (any Encodable & Sendable)? { ["name": name, "email": email] }
    typealias Response = User
}

// MARK: - Client Setup

@MainActor
class APIClient {
    static let shared = APIClient()

    private let client: NetworkClient

    private init() {
        let authInterceptor = AuthInterceptor(
            tokenProvider: { await TokenStorage.shared.token }
        )

        let loggingInterceptor = LoggingInterceptor(level: .minimal)

        let retryPolicy = RetryPolicy(
            maxRetries: 3,
            delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0.1)
        )

        self.client = NetworkClient(
            environment: APIEnvironment(),
            interceptors: [authInterceptor, loggingInterceptor],
            retryPolicy: retryPolicy,
            cache: ResponseCache(maxEntries: 50)
        )
    }

    func getUser(id: String) async throws -> User {
        try await client.request(GetUserEndpoint(id: id))
    }

    func createUser(name: String, email: String) async throws -> User {
        try await client.request(CreateUserEndpoint(name: name, email: email))
    }
}

// MARK: - Usage

Task {
    do {
        let user = try await APIClient.shared.getUser(id: "123")
        print("Got user: \(user.name)")
    } catch {
        print("Error: \(error)")
    }
}
```

## License

MIT License
