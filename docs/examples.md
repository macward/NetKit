# Examples

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

## Error Handling Patterns

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
