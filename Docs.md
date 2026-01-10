**Prompt para crear NetKit:**

```
Crear un Swift Package llamado "NetKit" - una capa de networking reutilizable, simple y segura.

## Requisitos Técnicos

- iOS 18+ / macOS 15+
- Sin dependencias externas, solo Foundation
- Async/await nativo
- Swift 6 compatible

## Arquitectura

Estructura por features:

```
Sources/NetKit/
├── Core/
│   ├── NetworkClient.swift
│   ├── NetworkClientProtocol.swift
│   ├── Endpoint.swift
│   └── RequestBuilder.swift
├── Interceptors/
│   ├── Interceptor.swift
│   ├── AuthInterceptor.swift
│   └── LoggingInterceptor.swift
├── Models/
│   ├── HTTPMethod.swift
│   ├── NetworkError.swift
│   ├── EmptyResponse.swift
│   └── Environment.swift
├── Cache/
│   └── ResponseCache.swift
├── Retry/
│   └── RetryPolicy.swift
├── Mock/
│   └── MockNetworkClient.swift
└── Extensions/
    └── URLRequest+Extensions.swift
```

## Endpoint Protocol

Structs conformando protocol con Response asociado:

```swift
public protocol Endpoint {
    associatedtype Response: Decodable
    
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String] { get }
    var queryParameters: [String: String] { get }
    var body: Encodable? { get }
}

// Defaults en extension
extension Endpoint {
    var headers: [String: String] { [:] }
    var queryParameters: [String: String] { [:] }
    var body: Encodable? { nil }
}
```

Ejemplo de uso:

```swift
struct GetUserEndpoint: Endpoint {
    let id: String
    
    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }
    
    typealias Response = User
}

struct DeleteUserEndpoint: Endpoint {
    let id: String
    
    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .delete }
    
    typealias Response = EmptyResponse
}
```

## EmptyResponse

Tipo especial para endpoints sin response body:

```swift
public struct EmptyResponse: Decodable, Equatable {
    public init() {}
}
```

El cliente detecta EmptyResponse y no intenta decodear el body.

## Environment Protocol

El usuario define sus environments:

```swift
public protocol Environment {
    var baseURL: URL { get }
    var defaultHeaders: [String: String] { get }
    var timeout: TimeInterval { get }
}

public extension Environment {
    var defaultHeaders: [String: String] { [:] }
    var timeout: TimeInterval { 30 }
}
```

## NetworkClient

### Inicialización

```swift
public final class NetworkClient: NetworkClientProtocol {
    public init(
        environment: Environment,
        interceptors: [Interceptor] = [],
        retryPolicy: RetryPolicy? = nil,
        cache: ResponseCache? = nil
    )
}
```

### API híbrida (simple + fluent)

```swift
// Caso simple (90% del uso)
let user = try await client.request(GetUserEndpoint(id: "123"))

// Con overrides puntuales
let user = try await client
    .request(GetUserEndpoint(id: "123"))
    .timeout(30)
    .header("X-Custom", "value")
    .send()
```

## NetworkClientProtocol

Para inyección de dependencias:

```swift
public protocol NetworkClientProtocol {
    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response
}
```

## MockNetworkClient

Incluido en el package para testing:

```swift
public final class MockNetworkClient: NetworkClientProtocol {
    // Stub respuestas
    public func stub<E: Endpoint>(_ type: E.Type, response: @escaping (E) -> E.Response)
    
    // Stub errores
    public func stubError<E: Endpoint>(_ type: E.Type, error: NetworkError)
    
    // Stub con delay
    public func stub<E: Endpoint>(_ type: E.Type, delay: TimeInterval, response: @escaping (E) -> E.Response)
    
    // Verificar llamadas
    public func callCount<E: Endpoint>(for type: E.Type) -> Int
    
    // Reset
    public func reset()
}
```

## NetworkError

```swift
public enum NetworkError: Error {
    case invalidURL
    case noConnection
    case timeout
    case unauthorized
    case forbidden
    case notFound
    case serverError(statusCode: Int)
    case decodingError(Error)
    case encodingError(Error)
    case unknown(Error)
}
```

## HTTPMethod

```swift
public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}
```

## Interceptors

```swift
public protocol Interceptor {
    func intercept(request: URLRequest) async throws -> URLRequest
    func intercept(response: HTTPURLResponse, data: Data) async throws -> Data
}
```

### AuthInterceptor

- Header injection vía interceptor
- Token refresh automático con retry (configurable)

### LoggingInterceptor

- Log de request/response
- Nivel de detalle configurable

## Features adicionales

- Retry automático con política configurable
- Cache de responses (configurable)
- Soporte para multipart/form-data
- Configuración de timeouts

## Principios

- El usuario maneja el lifecycle del cliente (no singleton)
- Extensible: el usuario puede crear sus propios endpoints, interceptors, etc.
- Type-safe: Response asociado al endpoint
- Testeable: protocol + mock incluido
```
