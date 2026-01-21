# Endpoints

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
