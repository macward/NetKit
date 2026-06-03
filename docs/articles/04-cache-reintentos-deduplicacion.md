# Caché, reintentos y deduplicación

> Artículo 4 de la serie *NetKit en profundidad*.

Tres problemas distintos, una misma raíz: **no hagas trabajo de red que no hace falta**. No vuelvas a pedir lo que ya tienes (caché). No te rindas a la primera ante un fallo transitorio (retry). No dispares la misma petición cinco veces a la vez (deduplicación). NetKit trae las tres piezas, y encajan entre sí sin que tengas que coordinarlas a mano.

## Caché que entiende HTTP

Lo fácil es cachear "durante X segundos". Lo correcto es **respetar lo que el servidor te dice**: `Cache-Control`, `ETag`, `Last-Modified`, `stale-while-revalidate`. NetKit hace lo segundo por defecto.

Activarla es pasar un `ResponseCache`:

```swift
let cache = ResponseCache(maxEntries: 100)

let client = NetworkClient(
    environment: APIEnvironment(),
    cache: cache
)
```

`ResponseCache` es un **actor** —seguro entre tareas concurrentes por construcción— con una política de caché HTTP por defecto (`HTTPCachePolicy`). Solo se cachean respuestas GET, y la decisión de cachear y por cuánto tiempo sale de los headers de la respuesta.

### Lo que la hace distinta: estados de frescura

Una caché ingenua solo sabe "hit" o "miss". La de NetKit distingue cuatro estados:

```swift
public enum CacheRetrievalResult: Sendable {
    case fresh(Data, CacheMetadata)              // válido, úsalo
    case stale(Data, CacheMetadata)              // caducado
    case needsRevalidation(Data, CacheMetadata)  // revalida con ETag/Last-Modified
    case miss                                    // no hay nada
}
```

Esto permite **stale-while-revalidate**: sirves la copia caducada al instante mientras revalidas en segundo plano. El usuario ve datos ya, y se actualizan si cambiaron. La metadata lleva el `ETag`, `Last-Modified`, cuándo se cacheó y cuándo expira:

```swift
public struct CacheMetadata: Sendable, Codable {
    public let etag: String?
    public let lastModified: String?
    public let cachedAt: Date
    public let expiresAt: Date?
    public let cacheControl: CacheControlDirective?
}
```

### Control por endpoint

Si no quieres depender solo de los headers, cada endpoint puede forzar su política:

```swift
public enum EndpointCachePolicy: Sendable {
    case respectHeaders          // por defecto: hazme caso al servidor
    case noCache                 // nunca cachear este endpoint
    case always(ttl: TimeInterval)   // cachea siempre, este TTL
    case overrideTTL(TimeInterval)   // cachea, pero con mi TTL
}
```

```swift
struct DashboardEndpoint: Endpoint {
    var path: String { "/dashboard" }
    var method: HTTPMethod { .get }
    var cachePolicy: EndpointCachePolicy { .always(ttl: 60) }  // 1 minuto
    typealias Response = Dashboard
}
```

### Invalidación

Cuando haces un POST/PUT que cambia datos, invalidas lo que ya no es válido:

```swift
await cache.invalidate(for: request)        // una entrada
await cache.invalidateAll()                 // todo
await cache.invalidateMatching(pattern: "/users")  // por patrón de URL
await cache.pruneExpired()                  // limpieza de caducados
```

## Reintentos con backoff exponencial

Las redes móviles fallan de forma transitoria: un timeout, un 503 mientras el servidor escala, una conexión que se cae al pasar de WiFi a 5G. Reintentar es lo correcto —pero reintentar **bien**.

```swift
// Por defecto: reintenta en errores de conexión, timeouts y 5xx
let retryPolicy = RetryPolicy(maxRetries: 3)

let client = NetworkClient(
    environment: APIEnvironment(),
    retryPolicy: retryPolicy
)
```

La política por defecto reintenta exactamente lo que tiene sentido reintentar: `.noConnection`, `.timeout`, `.serverError`, `.badGateway`, `.serviceUnavailable`, `.gatewayTimeout`. **No** reintenta un 401 o un 404 —eso no se arregla repitiendo.

### Estrategias de delay

```swift
public enum RetryDelay: Sendable {
    case immediate
    case fixed(TimeInterval)
    case exponential(base: TimeInterval, multiplier: Double, jitter: Double = 0, maxDelay: TimeInterval = 60)
}
```

El default es exponencial con jitter, que es lo que quieres en producción:

```swift
let retryPolicy = RetryPolicy(
    maxRetries: 3,
    delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0.1, maxDelay: 60)
)
```

¿Por qué el **jitter** importa? Sin él, si tu servidor se cae y vuelve, todos los clientes reintentan al mismo segundo exacto y lo tiran otra vez (el "thundering herd"). El jitter reparte los reintentos en el tiempo. El `maxDelay` evita que el backoff crezca sin límite.

### Lógica de reintento a medida

```swift
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
```

El closure recibe el `NetworkError` completo, así que puedes decidir según el `kind`, el status code o lo que necesites. Recuerda del [artículo 1](01-por-que-netkit-vs-alamofire.md) que `error.kind.isRetryable` y `error.kind.statusCode` ya te dan esa info masticada.

## Deduplicación: una sola request para diez llamadores

Este es el problema silencioso. Tres partes de la UI necesitan el mismo usuario al mismo tiempo:

```swift
async let user1 = client.request(GetUserEndpoint(id: "123"))
async let user2 = client.request(GetUserEndpoint(id: "123"))
async let user3 = client.request(GetUserEndpoint(id: "123"))

let users = try await [user1, user2, user3]
// 3 llamadas en tu código -> 1 sola request de red
```

Por defecto, los GET concurrentes idénticos se **deduplican**: NetKit ejecuta una request real y reparte el resultado a los tres llamadores. Cada uno decodifica su copia de forma independiente, y cancelar a uno no afecta a los demás.

### Política por endpoint

```swift
public enum DeduplicationPolicy: Sendable {
    case automatic   // GET deduplicados (default)
    case always      // dedupe incluso mutaciones
    case never       // nunca deduplicar este endpoint
}
```

| Política | Comportamiento |
|----------|----------------|
| `.automatic` | Deduplica solo GET (por defecto) |
| `.always` | Deduplica siempre, útil para POST idempotentes |
| `.never` | Desactiva dedupe, para GET con efectos secundarios |

```swift
// GET de analítica: cada llamada DEBE llegar al servidor
struct TrackEndpoint: Endpoint {
    var path: String { "/track" }
    var method: HTTPMethod { .get }
    var deduplicationPolicy: DeduplicationPolicy { .never }
    typealias Response = EmptyResponse
}
```

### Cómo funciona por dentro

- Las requests se identifican por **URL + método HTTP + hash del body**.
- La deduplicación ocurre **después de los interceptors** (con los headers de auth ya inyectados).
- Cada llamador **decodifica de forma independiente**.
- **Cancelar a un llamador no afecta** a los otros.
- Es thread-safe vía actores.

Que ocurra *después* de los interceptors es un detalle importante: dos requests con tokens distintos no se confunden como "la misma".

## Cómo encajan las tres

El orden del flujo es el que esperarías, y por eso no se pisan:

1. Se construye la request y se aplican interceptors (auth, etc.).
2. **Caché** (solo GET): si hay copia fresca, se devuelve sin tocar la red.
3. **Deduplicación**: si ya hay una request idéntica en vuelo, se engancha a ella.
4. Ejecución de red.
5. **Retry**: si falla con un error reintentable, espera el delay y vuelve al punto 4.
6. Se cachea la respuesta (según política) y se decodifica.

No tienes que orquestar nada: pasas `cache`, `retryPolicy` y la `deduplicationPolicy` del endpoint, y NetKit los compone.

## Cuándo usar qué

- **Caché** → GETs de datos que no cambian a cada segundo (perfiles, catálogos, configuración). `.respectHeaders` salvo que tu API no mande buenos headers.
- **Retry** → siempre activado con el default; sube `maxRetries` para operaciones críticas, baja para acciones que el usuario espera ya.
- **Dedupe** → déjalo en `.automatic`; cámbialo a `.never` solo en GETs con efectos (tracking, contadores) y a `.always` en POSTs idempotentes con clave de idempotencia.

## Siguiente paso

Hasta aquí, todo son requests que empiezan y terminan. Pero algunas APIs necesitan **mantener un canal abierto**: notificaciones, estados que cambian, chat. Sin montar WebSockets. Eso es el [artículo 5: long polling como AsyncSequence](05-long-polling.md).
</content>
