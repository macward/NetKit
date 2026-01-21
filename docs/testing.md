# Testing

NetKit includes a mock client for unit testing.

## MockNetworkClient

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

## MockNetworkClient API

### Stub Success Response

```swift
await mockClient.stub(EndpointType.self) { endpoint in
    // Return response based on endpoint properties
}
```

### Stub with Delay

```swift
await mockClient.stub(EndpointType.self, delay: 1.0) { endpoint in
    // Return response
}
```

### Stub Error

```swift
await mockClient.stubError(EndpointType.self, error: .notFound())
```

### Stub Sequence (for polling/repeated calls)

```swift
await mockClient.stubSequence(EndpointType.self, responses: [
    response1,
    response2,
    response3
])
```

### Stub Sequence with Mixed Results

```swift
await mockClient.stubSequence(EndpointType.self, sequence: [
    .success(response1),
    .failure(.timeout()),
    .success(response2)
])
```

### Stub Upload with Progress

```swift
await mockClient.stubUpload(
    UploadEndpoint.self,
    progressSequence: [
        TransferProgress(bytesCompleted: 500, totalBytes: 1000),
        TransferProgress(bytesCompleted: 1000, totalBytes: 1000, isComplete: true)
    ]
) { endpoint in
    UploadResponse(fileId: "123", size: 1000)
}
```

### Stub Download with Progress

```swift
await mockClient.stubDownload(
    DownloadEndpoint.self,
    progressSequence: [
        TransferProgress(bytesCompleted: 5000, totalBytes: 10000),
        TransferProgress(bytesCompleted: 10000, totalBytes: 10000, isComplete: true)
    ],
    destinationURL: URL(fileURLWithPath: "/tmp/test.zip")
)
```

### Verification Methods

```swift
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
