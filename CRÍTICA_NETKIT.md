# 🔍 Crítica Constructiva de NetKit

Análisis crítico del código base de NetKit con sugerencias de mejora y features adicionales.

---

## ❌ Problemas y Limitaciones Actuales

### 1. Cache muy limitado

**Ubicación:** `Sources/NetKit/Cache/ResponseCache.swift:110`

```swift
await cache.store(data: responseData, for: urlRequest, ttl: 300)
```

**Problemas:**
- ❌ TTL hardcodeado a 300 segundos (5 min) - no configurable por endpoint
- ❌ Solo in-memory, se pierde todo al cerrar la app
- ❌ **NO respeta HTTP cache headers** (Cache-Control, ETag, Last-Modified)
- ❌ La clave de cache no incluye headers de autenticación (riesgo de seguridad)
- ❌ "Oldest entry" se determina por `expiresAt` en vez de timestamp de acceso (no es verdadero LRU)

**Debería tener:**
```swift
protocol CachePolicy {
    func shouldCache(request: URLRequest, response: HTTPURLResponse) -> Bool
    func ttl(for response: HTTPURLResponse) -> TimeInterval
    func invalidationRules() -> [CacheInvalidationRule]
}

// Soporte para disk cache
enum CacheStorage {
    case memory(limit: ByteCountFormatter.Units)
    case disk(directory: URL, limit: ByteCountFormatter.Units)
    case hybrid(memory: ByteCountFormatter.Units, disk: ByteCountFormatter.Units)
}
```

---

### 2. NetworkError muy básico

**Ubicación:** `Sources/NetKit/Models/NetworkError.swift:4`

```swift
public enum NetworkError: Error, Sendable, Equatable {
    case serverError(statusCode: Int) // Solo el código, sin contexto
    case decodingError(Error)
    case unknown(Error)
}
```

**Problemas:**
- ❌ No incluye el request original (URL, headers, body) para debugging
- ❌ No tiene timestamp del error
- ❌ Falta información de retry attempts
- ❌ No distingue entre diferentes tipos de server errors (502, 503, 504)
- ❌ `Equatable` compara errores por `localizedDescription` (frágil)

**Debería ser:**
```swift
public struct NetworkError: Error, Sendable {
    let kind: ErrorKind
    let request: RequestSnapshot // URL, method, headers (sanitized)
    let response: ResponseSnapshot? // statusCode, headers
    let underlyingError: (any Error)?
    let timestamp: Date
    let retryAttempt: Int

    enum ErrorKind: Equatable {
        case invalidURL
        case timeout(afterSeconds: TimeInterval)
        case unauthorized(realm: String?)
        case serverUnavailable // 503
        case gatewayTimeout // 504
        case badGateway // 502
        case rateLimited(retryAfter: TimeInterval?)
        case decodingFailed(dataSize: Int, contentType: String?)
        // ...
    }
}
```

---

### 3. Falta observabilidad y métricas

**No hay forma de:**
- ❌ Medir request duration
- ❌ Contar success/failure rates
- ❌ Detectar slow endpoints
- ❌ Rastrear network conditions
- ❌ Integrar con Sentry, Firebase Crashlytics, DataDog

**Debería tener:**
```swift
protocol NetworkMetrics: Sendable {
    func recordRequest(
        endpoint: String,
        method: String,
        duration: TimeInterval,
        statusCode: Int?,
        error: NetworkError?
    ) async
}

// Ejemplo
final class NetworkTelemetry: NetworkMetrics {
    func recordRequest(...) async {
        // Send to analytics
        // Track slow requests
        // Alert on high error rates
    }
}
```

---

### 4. Sin soporte para uploads/downloads con progreso

```swift
// No hay forma de hacer esto:
let uploadTask = client.upload(
    file: fileURL,
    to: endpoint,
    progress: { bytesUploaded, totalBytes in
        // Update UI
    }
)
```

**Falta:**
- ❌ `URLSessionUploadTask` / `URLSessionDownloadTask` support
- ❌ Progress tracking con `AsyncStream<Progress>`
- ❌ Multipart form data builder
- ❌ Background uploads/downloads
- ❌ Chunked transfer encoding

---

### 5. Seguridad limitada

**Falta:**
- ❌ **Certificate pinning** (SSL pinning)
- ❌ Network tampering detection
- ❌ Sensitive data masking en logs (passwords, tokens, API keys)
- ❌ Request signing (HMAC, AWS Signature v4)
- ❌ Proxy detection

**Problema crítico en LoggingInterceptor:**
```swift
// Sources/NetKit/Interceptors/LoggingInterceptor.swift
print("Headers: \(request.allHTTPHeaderFields ?? [:])")
// ^ Esto puede loggear Authorization headers sin sanitizar!
```

---

### 6. Testing mock muy básico

```swift
// MockNetworkClient solo permite stubbing simple
await mock.stub(endpoint: GetUser.self, response: user)
```

**Falta:**
- ❌ Network condition simulation (slow 3G, packet loss)
- ❌ Response delay simulation realista
- ❌ Snapshot testing de requests
- ❌ Request matching por headers/body
- ❌ Fixture management system

---

## 🚀 Features que Agregaría

### 1. WebSockets support

Long polling está bien, pero WebSockets es más eficiente:

```swift
protocol WebSocketEndpoint {
    var path: String { get }
    func onMessage(_ message: Data) async
    func onError(_ error: Error) async
}

let socket = client.webSocket(endpoint: ChatSocket())
for await message in socket {
    // Handle message
}
```

---

### 2. Request deduplication

Si haces 10 requests idénticos simultáneos, ejecuta solo 1:

```swift
// Actualmente:
Task { let user = try await client.request(GetUser(id: 1)) } // Request 1
Task { let user = try await client.request(GetUser(id: 1)) } // Request 2 (duplicado!)

// Debería:
Task { let user = try await client.request(GetUser(id: 1)) } // Request 1
Task { let user = try await client.request(GetUser(id: 1)) } // Reutiliza Request 1
```

---

### 3. GraphQL support

```swift
struct GraphQLEndpoint: Endpoint {
    let query: String
    let variables: [String: Any]?

    var method: HTTPMethod { .post }
    var path: String { "/graphql" }
}
```

---

### 4. Request/Response middleware hooks

```swift
protocol NetworkEventObserver: Sendable {
    func willSendRequest(_ request: URLRequest) async
    func didReceiveResponse(_ response: HTTPURLResponse, data: Data) async
    func didFailWithError(_ error: NetworkError) async
}

// Use case: Analytics, logging, debugging
```

---

### 5. Structured concurrency task groups

Para ejecutar múltiples requests en paralelo:

```swift
let results = try await client.batch {
    GetUser(id: 1)
    GetPosts(userId: 1)
    GetComments(userId: 1)
}
// Retorna (User, [Post], [Comment])
```

---

### 6. Disk cache con HTTP compliance

```swift
let cache = DiskCache(
    directory: .cachesDirectory,
    maxSize: 100.megabytes,
    policy: .respectHTTPHeaders // ETag, Cache-Control, Expires
)
```

---

### 7. Certificate pinning

```swift
let client = NetworkClient(
    environment: env,
    securityPolicy: .pinned(
        certificates: [certificate],
        validateHost: true
    )
)
```

---

### 8. OpenAPI/Swagger code generation

```bash
netkit generate --spec openapi.yaml --output Sources/API
```

Genera automáticamente:
- Todos los endpoints
- Request/response models
- Environment configs

---

## 🎨 Mejoras de Diseño

### 1. Configuración centralizada

Actualmente la config está dispersa:

```swift
// Ahora:
let client = NetworkClient(
    environment: env,
    interceptors: [auth, logging],
    retryPolicy: retry,
    cache: cache,
    session: session,
    decoder: decoder,
    encoder: encoder
)
```

**Mejor:**
```swift
struct NetworkConfiguration {
    var environment: NetworkEnvironment
    var interceptors: [any Interceptor] = []
    var retryPolicy: RetryPolicy = .default
    var cachePolicy: CachePolicy = .automatic
    var security: SecurityPolicy = .default
    var logging: LoggingPolicy = .minimal
    var metrics: NetworkMetrics?
    var session: URLSession = .shared
    var decoder: JSONDecoder = .init()
    var encoder: JSONEncoder = .init()
}

let client = NetworkClient(configuration: config)
```

---

### 2. Typed HTTP status codes

```swift
// Mejor que statusCode: Int
enum HTTPStatusCode: Int, Sendable {
    case ok = 200
    case created = 201
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case rateLimited = 429
    case internalServerError = 500
    case badGateway = 502
    case serviceUnavailable = 503
    case gatewayTimeout = 504

    var isSuccess: Bool { (200..<300).contains(rawValue) }
    var isClientError: Bool { (400..<500).contains(rawValue) }
    var isServerError: Bool { (500..<600).contains(rawValue) }
}
```

---

### 3. Result builders para endpoints

```swift
@EndpointBuilder
var endpoints: [any Endpoint] {
    GetUser(id: 1)
    GetPosts(userId: 1)
    if shouldFetchComments {
        GetComments(userId: 1)
    }
}
```

---

## 📊 Resumen de Prioridades

| Prioridad | Feature | Impacto |
|-----------|---------|---------|
| 🔴 **Alta** | HTTP cache headers support | Ahorro de datos/batería |
| 🔴 **Alta** | Request/response metadata en errores | Debugging esencial |
| 🔴 **Alta** | Sensitive data sanitization en logs | Seguridad |
| 🟡 **Media** | Progress tracking para uploads | UX |
| 🟡 **Media** | Request deduplication | Performance |
| 🟡 **Media** | Network metrics/telemetry | Observability |
| 🟢 **Baja** | WebSockets | Feature adicional |
| 🟢 **Baja** | GraphQL support | Nice to have |
| 🟢 **Baja** | Code generation | DX improvement |

---

## ✅ Lo que me GUSTA mucho

- ✅ Protocol-oriented design impecable
- ✅ Zero dependencies (solo Foundation)
- ✅ Thread-safe (Sendable + Actor)
- ✅ Testing con MockNetworkClient
- ✅ Documentación excelente
- ✅ Async/await moderno
- ✅ Interceptor pattern bien implementado

---

## 🎯 Conclusión

**NetKit tiene bases sólidas**, pero le faltan features "production-grade" como:
- Cache inteligente con HTTP compliance
- Observabilidad y métricas
- Seguridad avanzada (certificate pinning, data sanitization)
- Mejor manejo de errores con contexto completo

**Recomendación:**
- ✅ Para proyectos personales o MVPs está **perfecto**
- ⚠️ Para apps enterprise necesitaría las mejoras mencionadas
- 🚀 La arquitectura permite agregar todas estas features sin breaking changes

---

**Fecha:** 2026-01-17
**Versión analizada:** main branch (commit: db8d6ae)
