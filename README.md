# NetKit

A simple, secure, and reusable networking layer for Swift. Features include:

- Type-safe API requests with `Endpoint` protocol
- Upload & download with real-time progress tracking
- Multipart form data support
- Long polling for real-time updates
- Automatic retry with exponential backoff
- Response caching with HTTP header support
- Request/response interceptors (auth, logging)
- Sensitive data sanitization in logs
- Full async/await support with Swift 6 concurrency

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

NetworkError is a struct with rich context for debugging:

```swift
public struct NetworkError: Error {
    public let kind: ErrorKind           // The type of error
    public let request: RequestSnapshot? // URL, method, sanitized headers
    public let response: ResponseSnapshot? // Status code, headers, body preview
    public let underlyingError: (any Error)?
    public let timestamp: Date
    public let retryAttempt: Int?
}

public enum ErrorKind {
    case invalidURL
    case noConnection
    case timeout
    case unauthorized      // 401
    case forbidden         // 403
    case notFound          // 404
    case noContent         // 204
    case rateLimited       // 429
    case badGateway        // 502
    case serviceUnavailable // 503
    case gatewayTimeout    // 504
    case serverError(statusCode: Int)  // Other 5xx
    case clientError(statusCode: Int)  // Other 4xx
    case decodingFailed
    case encodingFailed
    case unknown
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
        switch error.kind {
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

Log requests and responses with automatic sensitive data sanitization:

```swift
let loggingInterceptor = LoggingInterceptor(level: .verbose)
// Levels: .none, .minimal, .verbose

let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [loggingInterceptor]
)
```

### Sensitive Data Sanitization

By default, `LoggingInterceptor` automatically redacts sensitive data:

- **Headers**: Authorization, X-API-Key, Cookie, etc.
- **Query Parameters**: token, api_key, password, secret, etc.
- **JSON Body Fields**: password, secret, token, credentials, etc.

```swift
// Default sanitization (recommended for production)
let interceptor = LoggingInterceptor(level: .verbose)

// Custom sanitization rules
let customConfig = SanitizationConfig(
    sensitiveHeaders: ["X-Custom-Auth", "X-Secret"],
    sensitiveQueryParams: ["custom_token"],
    sensitiveBodyFields: ["customPassword", "apiSecret"]
)
let interceptor = LoggingInterceptor(level: .verbose, sanitization: customConfig)

// Disable sanitization (debugging only - NOT for production)
let interceptor = LoggingInterceptor(level: .verbose, sanitization: .none)

// Strict mode with additional fields (PCI compliance)
let interceptor = LoggingInterceptor(level: .verbose, sanitization: .strict)
```

Example log output with sanitization:
```
➡️ POST https://api.example.com/login?token=[REDACTED]
   Headers: ["Authorization": "[REDACTED]", "Content-Type": "application/json"]
   Body: {"username":"john","password":"[REDACTED]"}
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

## Long Polling

NetKit supports long polling for real-time updates. Long polling keeps a connection open until the server has data to send or a timeout occurs.

### Define a Long Polling Endpoint

```swift
struct MessagesEndpoint: LongPollingEndpoint {
    var path: String { "/messages/poll" }
    var method: HTTPMethod { .get }

    // Optional: customize polling behavior
    var pollingTimeout: TimeInterval { 30 }  // Default: 30s
    var retryInterval: TimeInterval { 1 }     // Default: 1s

    typealias Response = [Message]

    // Optional: stop polling based on response
    func shouldContinuePolling(after response: [Message]) -> Bool {
        // Continue polling until we receive a specific message
        !response.contains { $0.type == "disconnect" }
    }
}
```

### Start Polling

```swift
// Basic polling
for await messages in client.poll(MessagesEndpoint()) {
    print("New messages: \(messages)")
}

// With custom configuration
for await messages in client.poll(MessagesEndpoint(), configuration: .realtime) {
    handleMessages(messages)
}

// Limit to first N responses
for await messages in client.poll(MessagesEndpoint()).first(10) {
    print("Got batch: \(messages)")
}

// Stop based on condition
for await messages in client.poll(MessagesEndpoint()).while({ !$0.isEmpty }) {
    process(messages)
}
```

### Configuration Presets

```swift
// Short: 10s timeout, 0.5s retry (real-time critical)
let config = LongPollingConfiguration.short

// Standard: 30s timeout, 1s retry (balanced)
let config = LongPollingConfiguration.standard

// Long: 60s timeout, 2s retry (low server load)
let config = LongPollingConfiguration.long

// Realtime: 15s timeout, 0.1s retry (aggressive)
let config = LongPollingConfiguration.realtime

// Custom
let config = LongPollingConfiguration(
    timeout: 45,
    retryInterval: 2.0,
    maxConsecutiveErrors: 10
)
```

### Cancellation

Polling respects Swift's structured concurrency. Cancel the task to stop polling:

```swift
let pollingTask = Task {
    for await messages in client.poll(MessagesEndpoint()) {
        handleMessages(messages)
    }
}

// Later: stop polling
pollingTask.cancel()
```

### Error Handling

The polling stream automatically handles transient errors:

| Error | Behavior |
|-------|----------|
| Timeout | Reconnect immediately |
| 204 No Content | Wait `retryInterval`, poll again |
| 408 Request Timeout | Reconnect immediately |
| 5xx Server Error | Wait `retryInterval`, retry |
| Connection Lost | Wait `retryInterval * 2`, retry |
| 401/403/404 | Stop polling |
| Max consecutive errors | Stop polling |

## Upload & Download with Progress Tracking

NetKit provides upload and download functionality with real-time progress tracking using AsyncStream.

### File Upload

```swift
struct UploadEndpoint: Endpoint {
    var path: String { "/files/upload" }
    var method: HTTPMethod { .post }

    typealias Response = UploadResponse
}

struct UploadResponse: Codable, Sendable {
    let fileId: String
    let size: Int
}

// Upload a file with progress tracking
let fileURL = URL(fileURLWithPath: "/path/to/file.jpg")
let (progress, responseTask) = client.upload(file: fileURL, to: UploadEndpoint())

// Track progress
for await update in progress {
    print("Progress: \(Int((update.fractionCompleted ?? 0) * 100))%")

    if let speed = update.bytesPerSecond {
        print("Speed: \(Int(speed / 1024)) KB/s")
    }

    if let eta = update.estimatedTimeRemaining {
        print("ETA: \(Int(eta)) seconds")
    }
}

// Get the response
let response = try await responseTask.value
print("Uploaded file ID: \(response.fileId)")
```

### Multipart Form Data Upload

```swift
let formData = MultipartFormData()

// Add file data
formData.append(data: imageData, name: "avatar", filename: "photo.jpg")

// Add string fields
formData.append(value: "John Doe", name: "name")
formData.append(value: "john@example.com", name: "email")

// Add file from URL
try formData.append(fileURL: documentURL, name: "document", filename: "resume.pdf")

// Upload with progress
let (progress, responseTask) = client.upload(formData: formData, to: ProfileEndpoint())

for await update in progress {
    print("\(update)") // "50.0% 512 KB of 1 MB (256 KB/s) ETA: 2s"
}

let response = try await responseTask.value
```

### File Download

```swift
struct FileEndpoint: Endpoint {
    let fileId: String

    var path: String { "/files/\(fileId)" }
    var method: HTTPMethod { .get }

    typealias Response = EmptyResponse
}

// Download to a specific location
let destination = FileManager.default.temporaryDirectory
    .appendingPathComponent("downloaded.zip")

let (progress, responseTask) = client.download(from: FileEndpoint(fileId: "123"), to: destination)

// Track download progress
for await update in progress {
    let percent = Int((update.fractionCompleted ?? 0) * 100)
    let downloaded = ByteCountFormatter.string(fromByteCount: update.bytesCompleted, countStyle: .file)

    if let total = update.totalBytes {
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        print("\(percent)% - \(downloaded) of \(totalStr)")
    }
}

// Get the saved file URL
let savedURL = try await responseTask.value
print("File saved to: \(savedURL.path)")
```

### TransferProgress Properties

```swift
public struct TransferProgress {
    /// Bytes transferred so far
    let bytesCompleted: Int64

    /// Total expected bytes (nil if unknown)
    let totalBytes: Int64?

    /// Progress fraction from 0.0 to 1.0 (nil if total unknown)
    var fractionCompleted: Double?

    /// Whether the transfer has completed
    let isComplete: Bool

    /// Estimated seconds remaining (nil if cannot be calculated)
    let estimatedTimeRemaining: TimeInterval?

    /// Current transfer speed in bytes/second
    let bytesPerSecond: Double?
}
```

### Concurrent Progress Tracking

You can track progress while doing other work:

```swift
let (progress, responseTask) = client.upload(file: largeFileURL, to: UploadEndpoint())

// Start progress tracking in background
Task {
    for await update in progress {
        await MainActor.run {
            progressView.progress = update.fractionCompleted ?? 0
        }
    }
}

// Do other work while upload happens
await prepareNextUpload()

// Wait for upload to complete
let response = try await responseTask.value
```

### MIME Type Detection

`MultipartFormData` automatically detects MIME types from file extensions:

| Extension | MIME Type |
|-----------|-----------|
| jpg, jpeg | image/jpeg |
| png | image/png |
| gif | image/gif |
| pdf | application/pdf |
| json | application/json |
| mp4 | video/mp4 |
| mp3 | audio/mpeg |
| zip | application/zip |
| ... | (50+ types supported) |

You can also specify MIME types explicitly:

```swift
formData.append(data: data, name: "file", filename: "data.bin", mimeType: "application/octet-stream")
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
        await mockClient.stubError(GetUserEndpoint.self, error: .notFound())

        // Test error handling
        do {
            _ = try await userService.getUser(id: "invalid")
            XCTFail("Expected error")
        } catch let error as NetworkError {
            XCTAssertEqual(error.kind, .notFound)
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
await mockClient.stubError(EndpointType.self, error: .notFound())

// Stub sequence (for polling/repeated calls)
await mockClient.stubSequence(EndpointType.self, responses: [
    response1,
    response2,
    response3
])

// Stub sequence with mixed results
await mockClient.stubSequence(EndpointType.self, sequence: [
    .success(response1),
    .failure(.timeout()),
    .success(response2)
])

// Stub upload with progress
await mockClient.stubUpload(
    UploadEndpoint.self,
    progressSequence: [
        TransferProgress(bytesCompleted: 500, totalBytes: 1000),
        TransferProgress(bytesCompleted: 1000, totalBytes: 1000, isComplete: true)
    ]
) { endpoint in
    UploadResponse(fileId: "123", size: 1000)
}

// Stub download with progress
await mockClient.stubDownload(
    DownloadEndpoint.self,
    progressSequence: [
        TransferProgress(bytesCompleted: 5000, totalBytes: 10000),
        TransferProgress(bytesCompleted: 10000, totalBytes: 10000, isComplete: true)
    ],
    destinationURL: URL(fileURLWithPath: "/tmp/test.zip")
)

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
} catch let error as NetworkError {
    switch error.kind {
    case .unauthorized:
        // Handle 401 - redirect to login
        break
    case .notFound:
        // Handle 404 - show not found UI
        break
    case .noConnection:
        // Handle offline - show retry option
        break
    case .timeout:
        // Handle timeout - suggest retry
        break
    case .serverError(let statusCode):
        // Handle 5xx errors
        print("Server error: \(statusCode)")
    case .decodingFailed:
        // Handle JSON parsing errors
        if let underlying = error.underlyingError {
            print("Failed to decode: \(underlying)")
        }
    default:
        print("Error: \(error.errorDescription ?? "Unknown")")
    }

    // Access rich error context for debugging
    if let request = error.request {
        print("Failed request: \(request.method ?? "") \(request.url?.absoluteString ?? "")")
    }
    if let response = error.response {
        print("Response status: \(response.statusCode)")
    }
} catch {
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
