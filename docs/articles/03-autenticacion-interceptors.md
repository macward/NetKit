# Autenticación e interceptors

> Artículo 3 de la serie *NetKit en profundidad*.

Casi ninguna API real es pública. Antes o después necesitas meter un token en cada request, refrescarlo cuando el servidor responde 401, y hacerlo **sin** que cinco requests en paralelo disparen cinco refreshes simultáneos. Este es el problema clásico de la capa de red, y donde muchas implementaciones caseras se rompen.

NetKit lo resuelve con dos piezas: el **protocolo `Interceptor`** (un pipeline genérico) y el **`AuthInterceptor`** (la implementación lista para usar, con coordinación de refresh incluida).

## El pipeline: qué es un interceptor

Un interceptor puede tocar la request antes de enviarla y la respuesta antes de decodificarla:

```swift
public protocol Interceptor: Sendable {
    func intercept(request: URLRequest) async throws -> URLRequest
    func intercept(response: HTTPURLResponse, data: Data) async throws -> Data
}

public extension Interceptor {
    func intercept(request: URLRequest) async throws -> URLRequest { request }
    func intercept(response: HTTPURLResponse, data: Data) async throws -> Data { data }
}
```

Las dos vienen con implementación por defecto, así que solo implementas la mitad que te interesa. Y como son `async throws`, dentro puedes leer del Keychain, llamar a otro servicio o abortar la request lanzando un error.

Los interceptors se aplican **en orden** sobre cada request, después de construirla. Por eso encajan tan bien con auth: el token se inyecta una vez, en el sitio correcto del flujo, antes de que entre la caché o la deduplicación.

## Bearer token: el caso del 95%

```swift
let authInterceptor = AuthInterceptor(
    tokenProvider: {
        await TokenManager.shared.accessToken
    }
)

let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [authInterceptor]
)
```

El `tokenProvider` es un closure `async` que devuelve el token actual. NetKit lo llama en cada request y añade `Authorization: Bearer <token>`. Como es async, puedes leerlo de almacenamiento seguro sin bloquear nada.

La firma completa te deja personalizar el header y el prefijo:

```swift
public init(
    headerName: String = "Authorization",
    tokenPrefix: String? = "Bearer",
    tokenProvider: @escaping @Sendable () async throws -> String?,
    onUnauthorized: (@Sendable () async throws -> Void)? = nil
)
```

## API key: cambia el header y quita el prefijo

```swift
let apiKeyInterceptor = AuthInterceptor(
    headerName: "X-API-Key",
    tokenPrefix: nil,             // sin "Bearer "
    tokenProvider: { "your-api-key" }
)
```

El mismo tipo cubre Bearer y API key cambiando dos parámetros. No hay dos clases distintas que aprender.

## Refresh ingenuo en 401

La versión simple: cuando llega un 401, ejecuta una acción (refrescar o desloguear):

```swift
let authInterceptor = AuthInterceptor(
    tokenProvider: { await TokenManager.shared.accessToken },
    onUnauthorized: {
        try await TokenManager.shared.refreshToken()
    }
)
```

Esto funciona… hasta que tienes tráfico real. Imagina que el token caduca y la pantalla dispara **seis** requests a la vez. Las seis reciben 401. Las seis llaman a `onUnauthorized`. Ahora tienes seis refreshes concurrentes peleándose por el mismo refresh token —y muchos backends invalidan el refresh token tras usarlo una vez, así que cinco de esos seis fallan y deslogueas al usuario por error.

Este es **el** bug clásico de las capas de red caseras.

## Refresh coordinado: el actor que arregla la carrera

NetKit trae un `TokenRefreshCoordinator`, un **actor** cuyo trabajo es garantizar que, ante N peticiones de refresh simultáneas, **solo se ejecute uno** y los demás esperen a su resultado:

```swift
public actor TokenRefreshCoordinator {
    public init(refreshHandler: @escaping @Sendable () async throws -> Void)
    public func refreshIfNeeded() async throws
}
```

Se lo pasas al `AuthInterceptor` por su segundo init:

```swift
let coordinator = TokenRefreshCoordinator {
    try await TokenManager.shared.refreshToken()
}

let authInterceptor = AuthInterceptor(
    tokenProvider: { await TokenManager.shared.accessToken },
    refreshCoordinator: coordinator
)

let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [authInterceptor]
)
```

Ahora las seis requests que reciben 401 llaman a `refreshIfNeeded()`. El actor serializa: el primero refresca, los otros cinco esperan ese mismo resultado y reusan el token nuevo. **Un solo refresh, cero deslogueos espurios.** Esa garantía es difícil de escribir bien a mano y aquí es un parámetro de constructor.

> Comparado con Alamofire: allí esto se resuelve implementando `RequestInterceptor` con tu propia lógica de cola y locks. NetKit te da el actor ya hecho.

## Logging que no filtra secretos

El `LoggingInterceptor` saca por consola lo que pasa por la red. La gracia está en que **sanea datos sensibles por defecto**:

```swift
public init(
    level: LogLevel = .minimal,
    sanitization: SanitizationConfig = .default,
    subsystem: String = Bundle.main.bundleIdentifier ?? "NetKit",
    category: String = "NetKit"
)
```

Con tres niveles:

```swift
public enum LogLevel: Sendable {
    case none
    case minimal   // método + URL
    case verbose   // método, URL, headers, body
}
```

Aunque pongas `.verbose`, la `SanitizationConfig` por defecto te tapa el `Authorization` y otros campos sensibles, así que no acabas con tokens en claro en los logs de producción. Usa `os.Logger` por debajo (subsistema y categoría configurables), así que se integra con Console.app.

```swift
let logging = LoggingInterceptor(level: .verbose)
let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [authInterceptor, logging]
)
```

## Tu propio interceptor

El protocolo es la puerta de extensión. ¿Necesitas un `X-Request-ID` por request para trazado distribuido? Diez líneas:

```swift
struct RequestIDInterceptor: Interceptor {
    func intercept(request: URLRequest) async throws -> URLRequest {
        var modified = request
        modified.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return modified
    }
}
```

Y lo enchufas en el orden que quieras junto a los demás:

```swift
let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [authInterceptor, logging, RequestIDInterceptor()]
)
```

Los interceptors se ejecutan en el orden del array. Pon auth antes de logging si quieres ver el header inyectado; pon logging primero si quieres ver la request "cruda".

## Cuándo usar qué

- `AuthInterceptor` con `tokenProvider` → toda API con Bearer o API key.
- `AuthInterceptor` + `onUnauthorized` → apps de bajo tráfico donde el refresh concurrente no es un problema real.
- `AuthInterceptor` + `TokenRefreshCoordinator` → **cualquier app con tráfico paralelo serio**. Es la opción correcta por defecto en cuanto tengas más de una request a la vez.
- `LoggingInterceptor` → siempre en debug; en producción con `.minimal` o `.none`.
- Interceptor propio → trazado, headers dinámicos, métricas custom, feature flags por request.

## Siguiente paso

Con auth resuelta, la siguiente capa que diferencia una app rápida de una lenta es **qué haces con las respuestas**: cachearlas bien, reintentar lo que falla y no disparar la misma request diez veces. Eso es el [artículo 4: caché, reintentos y deduplicación](04-cache-reintentos-deduplicacion.md).
</content>
