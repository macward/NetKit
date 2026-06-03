# Serie: NetKit en profundidad

Una serie de artículos técnicos sobre **cuándo** y **cómo** usar NetKit, y **por qué** elegirlo frente a las alternativas habituales (Alamofire, `URLSession` a pelo).

Cada artículo es autocontenido pero la serie sigue un orden natural: de la decisión de adopción a las features avanzadas.

| # | Artículo | De qué trata |
|---|----------|--------------|
| 01 | [¿Por qué NetKit y no Alamofire?](01-por-que-netkit-vs-alamofire.md) | Comparativa honesta. Cuándo NetKit gana, cuándo no. |
| 02 | [Primeros pasos: endpoints type-safe](02-primeros-pasos-endpoints.md) | El modelo `Endpoint` y por qué el tipado fuerte cambia las reglas. |
| 03 | [Autenticación e interceptors](03-autenticacion-interceptors.md) | Bearer, API keys, refresh coordinado de tokens y pipeline propio. |
| 04 | [Caché, reintentos y deduplicación](04-cache-reintentos-deduplicacion.md) | Caché que respeta HTTP, backoff exponencial y dedupe de requests. |
| 05 | [Long polling como AsyncSequence](05-long-polling.md) | Tiempo real sin WebSockets, integrado con `for await`. |
| 06 | [Subidas, descargas y progreso](06-transfers-progreso.md) | Multipart, progreso en streaming y cancelación estructurada. |
| 07 | [Seguridad: certificate pinning](07-certificate-pinning.md) | Protección MITM con rotación de certificados sin downtime. |
| 08 | [Testing sin dolor](08-testing.md) | `MockNetworkClient`, inyección de dependencias y tests de polling. |

## A quién va dirigida

Desarrolladores Swift que ya conocen `async/await` y han sufrido (o disfrutado) Alamofire o `URLSession`. No es un tutorial de networking desde cero: asume que sabes qué es un `Decodable` y un `URLRequest`.

## Contexto técnico

NetKit apunta a **iOS 18+ / macOS 15+**, está escrito en **Swift 6** con concurrencia estricta y **cero dependencias externas**. Todo lo que verás en esta serie está en la librería estándar de NetKit, sin paquetes adicionales.
</content>
</invoke>
