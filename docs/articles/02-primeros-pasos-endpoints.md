# Primeros pasos: endpoints type-safe

> Artículo 2 de la serie *NetKit en profundidad*.

En el [artículo anterior](01-por-que-netkit-vs-alamofire.md) dijimos que el gran cambio de NetKit es que **el tipo de la respuesta vive en el endpoint, no en el call site**. Este artículo es sobre eso: cómo se modela un endpoint, por qué el patrón funciona y cómo llegar de "0 a primer request" en cinco minutos.

## El entorno: una sola fuente para baseURL y defaults

Antes de los endpoints, defines tu entorno. Es un protocolo con tres propiedades, dos con valor por defecto:

```swift
public protocol NetworkEnvironment: Sendable {
    var baseURL: URL { get }
    var defaultHeaders: [String: String] { get }  // default: [:]
    var timeout: TimeInterval { get }              // default: 30
}
```

Una implementación típica:

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

¿Por qué un protocolo y no un struct con un init? Porque te permite tener `ProductionEnvironment`, `StagingEnvironment` y `LocalEnvironment` como tipos distintos, intercambiables por inyección, sin un `if` repartido por el código. La `baseURL` y los headers comunes se definen **una vez**.

## El endpoint: un struct que se describe a sí mismo

Aquí está el protocolo completo. Fíjate en cuántas propiedades tienen valor por defecto: solo `path` y `method` son obligatorias.

```swift
public protocol Endpoint: Sendable {
    associatedtype Response: Decodable & Sendable

    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String] { get }          // default: [:]
    var queryParameters: [String: String] { get }   // default: [:]
    var body: (any Encodable & Sendable)? { get }    // default: nil
    var cacheTTL: TimeInterval? { get }              // default: nil
    var cachePolicy: EndpointCachePolicy { get }     // default: .respectHeaders
    var deduplicationPolicy: DeduplicationPolicy { get } // default: .automatic
}
```

El `associatedtype Response: Decodable & Sendable` es la clave de todo. Cada endpoint declara su tipo de respuesta, y `client.request(_:)` lo usa como tipo de retorno.

### GET simple

```swift
struct GetUsersEndpoint: Endpoint {
    var path: String { "/users" }
    var method: HTTPMethod { .get }

    typealias Response = [User]
}

let users = try await client.request(GetUsersEndpoint())  // -> [User]
```

### GET con query parameters

Los parámetros son datos del struct, no concatenación de strings:

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

NetKit construye la URL final (baseURL + path + query) y se encarga del encoding. Tú piensas en `query` y `page`, no en `?q=john&page=1`.

### POST con body

El `body` es cualquier `Encodable & Sendable`. NetKit lo serializa con el `JSONEncoder` del cliente:

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

let newUser = try await client.request(
    CreateUserEndpoint(name: "John", email: "john@example.com")
)
```

¿No quieres un struct dedicado para el body? Un diccionario también es `Encodable`:

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

### DELETE y respuestas vacías

Cuando el servidor responde 204 / cuerpo vacío, usa `EmptyResponse`:

```swift
struct DeleteUserEndpoint: Endpoint {
    let id: String

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .delete }

    typealias Response = EmptyResponse
}

try await client.request(DeleteUserEndpoint(id: "123"))
```

`EmptyResponse` es un `Decodable` vacío de la propia librería: no inventas un tipo dummy.

## El cliente: lo mínimo y lo máximo

Crear el cliente puede ser tan simple como esto:

```swift
let client = NetworkClient(environment: APIEnvironment())
```

…o tan completo como esto, porque todo lo demás tiene valor por defecto:

```swift
public init(
    environment: NetworkEnvironment,
    interceptors: [any Interceptor] = [],
    retryPolicy: RetryPolicy? = nil,
    cache: ResponseCache? = nil,
    session: URLSession = .shared,
    decoder: JSONDecoder = JSONDecoder(),
    encoder: JSONEncoder = JSONEncoder(),
    metricsCollector: (any MetricsCollector)? = nil,
    requestKeyStrategy: any RequestKeyStrategy = DefaultRequestKeyStrategy()
)
```

Empiezas con lo mínimo y vas activando piezas (interceptors, caché, retry…) según las necesitas. Cada una es un parámetro opcional, no una subclase ni un wrapper.

## El API fluido para lo que cambia por request

El endpoint describe lo que es *estable*. Para lo que cambia request a request (un timeout puntual, un header de trazado), está el builder:

```swift
let user = try await client
    .request(GetUserEndpoint(id: "123"))
    .timeout(60)
    .header("X-Request-ID", UUID().uuidString)
    .headers(["X-Custom": "value"])
    .send()
```

`client.request(endpoint)` está **sobrecargado**: o devuelve directamente `E.Response` (si lo esperas con `try await`), o devuelve un `RequestBuilder<E>` si encadenas `.timeout(...)`, `.header(...)` y cierras con `.send()`. El compilador elige según el contexto.

La precedencia de headers, de menor a mayor: **defaults del entorno → headers del endpoint → headers adicionales del builder**. Lo específico gana.

## El patrón que estás adoptando sin darte cuenta

Cada endpoint es un struct pequeño, inmutable y `Sendable`. Esto tiene consecuencias que se notan a los meses:

- **Descubribilidad**: autocompletar te lista tus endpoints como tipos.
- **Refactor seguro**: cambiar la forma de la respuesta es cambiar un `typealias`; el compilador te lleva a todos los call sites rotos.
- **Testeable**: un endpoint es un valor; puedes inspeccionarlo, compararlo y stubbearlo (lo veremos en el [artículo 8](08-testing.md)).
- **Sin strings mágicos**: la ruta vive con el tipo, no esparcida por view models.

## Cuándo usar qué

- Endpoint con propiedades por defecto → el 90% de tus llamadas.
- `queryParameters` → filtros, paginación, búsqueda.
- `body` con struct dedicado → payloads con forma estable.
- `body` con diccionario → updates parciales rápidos.
- `EmptyResponse` → DELETE y endpoints sin cuerpo.
- Builder `.timeout/.header/.send` → ajustes por request, no por endpoint.

## Siguiente paso

Ya sabes describir endpoints y disparar requests con tipado fuerte. Lo siguiente que toda app real necesita: **meter el token en cada request y refrescarlo cuando caduca** sin condiciones de carrera. Eso es el [artículo 3: autenticación e interceptors](03-autenticacion-interceptors.md).
</content>
