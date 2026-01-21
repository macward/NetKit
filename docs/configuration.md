# Configuration

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
