# Getting Started

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
