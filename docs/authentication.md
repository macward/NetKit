# Authentication

## Bearer Token Authentication

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

## API Key Authentication

```swift
let apiKeyInterceptor = AuthInterceptor(
    headerName: "X-API-Key",
    tokenPrefix: nil,  // No prefix
    tokenProvider: { "your-api-key" }
)
```

## Token Refresh on 401

```swift
let authInterceptor = AuthInterceptor(
    tokenProvider: { await TokenManager.shared.accessToken },
    onUnauthorized: {
        // Refresh token or logout
        try await TokenManager.shared.refreshToken()
    }
)
```

## Custom Interceptors

Create your own interceptors for custom request/response handling:

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

Use multiple interceptors together:

```swift
let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [authInterceptor, loggingInterceptor, customInterceptor]
)
```
