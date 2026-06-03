# ¿Por qué NetKit y no Alamofire?

> Artículo 1 de la serie *NetKit en profundidad*.

Alamofire lleva más de una década siendo la respuesta por defecto a "¿qué uso para networking en Swift?". Es maduro, está probado en millones de apps y cubre prácticamente todo. Entonces, ¿por qué escribir —y por qué adoptar— otra librería de red en 2026?

La respuesta corta: **porque el lenguaje cambió**. Swift 6, la concurrencia estricta, los actores y `Sendable` no son features que se "añaden" a una librería; son decisiones que se toman en la primera línea de código. NetKit nace de esa primera línea. Alamofire arrastra diez años de compatibilidad hacia atrás.

Este artículo no va a venderte humo. Vamos a comparar de verdad, y al final te voy a decir **cuándo NO deberías usar NetKit**.

## El problema de fondo: el tipo de la respuesta vive en el call site

En `URLSession` y en Alamofire, el endpoint y el tipo que decodifica viven en lugares distintos. Mira el patrón clásico de Alamofire:

```swift
// Alamofire
AF.request("https://api.example.com/users/123")
    .responseDecodable(of: User.self) { response in
        switch response.result {
        case .success(let user): print(user.name)
        case .failure(let error): print(error)
        }
    }
```

O su versión async:

```swift
// Alamofire (Concurrency)
let user = try await AF.request("https://api.example.com/users/123")
    .serializingDecodable(User.self)
    .value
```

El `User.self` está en el sitio de la llamada. Nada te impide pedir `Product.self` por error a la URL de usuarios. La URL es un string. El tipo de la respuesta es un parámetro suelto. **El compilador no te protege.**

NetKit invierte esto. El endpoint **es** un tipo, y ese tipo declara qué devuelve:

```swift
// NetKit
struct GetUserEndpoint: Endpoint {
    let id: String

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }

    typealias Response = User
}

let user = try await client.request(GetUserEndpoint(id: "123"))
//  ^ el compilador ya sabe que esto es User. No hay forma de equivocarse.
```

`request(_:)` usa un `associatedtype Response` del protocolo `Endpoint`. El tipo de retorno se deriva del endpoint. No puedes pedir el tipo equivocado porque no hay ningún tipo que pasar: el endpoint lo lleva dentro. Esto es **una sola fuente de verdad** por endpoint: la ruta, el método, el body y el tipo de respuesta están en el mismo struct.

## Concurrencia: retrofit vs. nativo

Alamofire empezó en la era de los closures y de Objective-C. Su soporte de `async/await` es una capa encima de un core construido alrededor de callbacks y colas (`DispatchQueue`). Funciona, pero `Sendable` y el aislamiento de actores se han ido auditando incrementalmente sobre una superficie enorme.

NetKit está construido al revés:

- `NetworkClient` es un `final class ... Sendable`.
- `ResponseCache` es un `actor`.
- `MockNetworkClient` es un `actor`.
- `TokenRefreshCoordinator` es un `actor`.
- **Todo** el API público es `Sendable`.

```swift
public final class NetworkClient: NetworkClientProtocol, Sendable { ... }
public actor ResponseCache { ... }
public actor TokenRefreshCoordinator { ... }
```

¿Qué significa esto en la práctica? Que compilas con concurrencia estricta de Swift 6 y NetKit no te genera warnings. No tienes que envolver nada en `@preconcurrency import`, ni luchar con "capture of non-Sendable type". El refresh de tokens ante varios 401 simultáneos no es un parche: es un actor diseñado para coordinar esa carrera (lo veremos en el artículo 3).

## Cero dependencias

Alamofire es una dependencia. Una buena, pero una dependencia: aumenta tu tiempo de compilación, tu superficie de seguridad y te ata a su ciclo de releases. Si Apple cambia algo en `URLSession`, esperas a que Alamofire lo adopte.

NetKit **no tiene dependencias externas**. Es Foundation y concurrencia de Swift. El binario que añades a tu app es solo lo que vas a usar, no un framework de propósito general que cubre casos que nunca tocarás (Combine publishers, `EventMonitor`, `NetworkReachabilityManager`, RxSwift bridges…).

## Errores con contexto, no un `enum` plano

Cuando algo falla en producción, un `case .timeout` te dice *qué* pasó pero no *dónde* ni *con qué*. El `NetworkError` de NetKit lleva el contexto pegado:

```swift
public struct NetworkError: Error, Sendable, Equatable {
    public let kind: ErrorKind            // qué tipo de error
    public let request: RequestSnapshot?  // URL, método, headers saneados
    public let response: ResponseSnapshot? // status, headers, preview del body
    public let underlyingError: (any Error)?
    public let timestamp: Date
    public let retryAttempt: Int?         // en qué reintento falló
}
```

El `ResponseSnapshot` incluye un `bodyPreview` (los primeros 512 bytes, UTF-8 safe) y el `RequestSnapshot` ya viene con los headers **saneados** (sin tokens en claro). Cuando logueas o reportas a Crashlytics, tienes la foto completa sin filtrar secretos.

Y el `ErrorKind` sabe sobre sí mismo:

```swift
if error.kind.isRetryable { /* ... */ }
if error.kind.isServerError { /* ... */ }
let code: Int? = error.kind.statusCode
```

## Lo que viene "en la caja"

Alamofire también trae muchas de estas piezas, así que aquí lo honesto es comparar el *diseño*, no la *existencia*:

| Necesidad | NetKit | Alamofire |
|-----------|--------|-----------|
| Tipado de respuesta | En el `Endpoint` (compile-time) | En el call site (`of: T.self`) |
| Reintentos | `RetryPolicy` con backoff + jitter | `RequestInterceptor` / `RetryPolicy` |
| Caché | `ResponseCache` HTTP-aware (ETag, `Cache-Control`, stale-while-revalidate) | Vía `URLCache` / configuración |
| Deduplicación de requests concurrentes | Integrada, por política de endpoint | Manual |
| Long polling | `AsyncSequence` nativo (`for await`) | Manual |
| Certificate pinning | `SecurityPolicy` + sesión pinneada | `ServerTrustManager` |
| Mock para tests | `MockNetworkClient` de primera clase | `URLProtocol` / mocks manuales |
| Concurrencia estricta Swift 6 | Por diseño | En adopción progresiva |
| Dependencias | 0 | Es la dependencia |

La diferencia clave no es "tiene más features", es que las features de NetKit están **diseñadas para encajar entre sí y con Swift moderno**, en una superficie pequeña que cabe en la cabeza.

## Cuándo NO usar NetKit (sé honesto contigo mismo)

NetKit no es la respuesta para todo. **Elige Alamofire (o `URLSession` directamente) si:**

- **Necesitas soportar iOS 17 o anterior.** NetKit exige **iOS 18+ / macOS 15+**. Si tu base de usuarios incluye OS antiguos, NetKit ni siquiera compila para ellos.
- **Dependes de features específicas de Alamofire**: `EventMonitor` para instrumentación detallada, `NetworkReachabilityManager`, publishers de Combine, o su ecosistema de plugins.
- **Tu equipo ya domina Alamofire** y el coste de migración no compensa para un proyecto en mantenimiento.
- **Necesitas la garantía de una comunidad enorme**: Stack Overflow, miles de issues resueltos, batalla probada en producción a una escala que una librería nueva todavía no tiene.

NetKit es para proyectos **nuevos o modernos**, sobre OS recientes, donde valoras el tipado fuerte, la concurrencia limpia de Swift 6 y una superficie mínima sin dependencias.

## Cuándo SÍ usar NetKit

- App nueva con target **iOS 18+ / macOS 15+**.
- Quieres **type safety** real entre endpoint y respuesta.
- Compilas con **concurrencia estricta** y no quieres pelear con `Sendable`.
- Te importa **no añadir dependencias** de terceros.
- Necesitas caché HTTP correcta, reintentos, dedupe o long polling **sin pegar tres librerías**.
- Quieres **tests rápidos y deterministas** sin montar un servidor mock.

## Conclusión

Alamofire es una herramienta excelente para el mundo que la vio nacer: muchos OS, muchos paradigmas, máxima cobertura. NetKit es una herramienta para el mundo de hoy: Swift 6, un rango de OS reciente, concurrencia estricta y tipado fuerte como ciudadanos de primera clase.

No es "mejor" en abstracto. Es **más ajustado** a un proyecto moderno. Si el tuyo lo es, los próximos artículos te muestran cómo sacarle partido —empezando por el corazón de todo: el [modelo de endpoints type-safe](02-primeros-pasos-endpoints.md).
</content>
