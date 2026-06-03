# Long polling como AsyncSequence

> Artículo 5 de la serie *NetKit en profundidad*.

No todo en una app es "pide y olvida". A veces necesitas **esperar a que algo cambie en el servidor**: un mensaje nuevo, el estado de un pago, el progreso de un job. Las opciones clásicas son WebSockets (potentes pero pesados de operar) o long polling (el servidor mantiene la request abierta hasta que hay novedad o expira el timeout).

El long polling tiene mala fama por lo incómodo que es escribirlo a mano: un bucle, control de timeouts, reintentos, manejo de errores consecutivos, cancelación... NetKit lo convierte en algo que ya sabes consumir: un `AsyncSequence`. Lo recorres con `for await` y se acabó.

## El endpoint de polling

`LongPollingEndpoint` extiende `Endpoint` con tres miembros, todos con valor por defecto:

```swift
public protocol LongPollingEndpoint: Endpoint {
    var pollingTimeout: TimeInterval { get }   // default: 30
    var retryInterval: TimeInterval { get }    // default: 1
    func shouldContinuePolling(after response: Response) -> Bool  // default: true
}
```

Como hereda de `Endpoint`, todo lo que ya sabes (path, method, query, body, tipo `Response`) sigue igual. Solo añades el comportamiento de polling:

```swift
struct MessagesEndpoint: LongPollingEndpoint {
    let channelID: String

    var path: String { "/channels/\(channelID)/messages" }
    var method: HTTPMethod { .get }
    var pollingTimeout: TimeInterval { 30 }

    typealias Response = [Message]

    // Para opcionalmente cuando ya no hay nada que esperar
    func shouldContinuePolling(after response: [Message]) -> Bool {
        true  // sigue indefinidamente
    }
}
```

## Consumirlo: `for await` y ya

```swift
for await messages in client.poll(MessagesEndpoint(channelID: "general")) {
    print("Llegaron \(messages.count) mensajes")
    updateUI(with: messages)
}
```

`client.poll(_:)` devuelve un `LongPollingStream<E>`, que conforma `AsyncSequence`. Cada iteración del `for await` es una respuesta nueva del servidor. NetKit se encarga del bucle, los timeouts y los reintentos por debajo. Cuando la tarea que contiene el `for await` se cancela, el polling se detiene limpiamente —cancelación estructurada de Swift, gratis.

## Configuración: presets o a medida

Si necesitas afinar tiempos sin tocar el endpoint, pásale una `LongPollingConfiguration`:

```swift
public struct LongPollingConfiguration: Sendable, Equatable {
    public init(
        timeout: TimeInterval = 30,
        retryInterval: TimeInterval = 1,
        maxConsecutiveErrors: Int? = 5
    )
}
```

Hay presets para los casos habituales:

```swift
.short      // timeout 10s, retry 0.5s
.standard   // timeout 30s, retry 1s
.long       // timeout 60s, retry 2s
.realtime   // timeout 15s, retry 0.1s
```

```swift
for await status in client.poll(PaymentStatusEndpoint(id: "tx_1"), configuration: .realtime) {
    if status.isFinal { break }
    show(status)
}
```

El `maxConsecutiveErrors` es la red de seguridad: si el servidor falla N veces seguidas, el stream se rinde en vez de martillear para siempre. Ponlo a `nil` para reintentar indefinidamente (úsalo con cabeza).

## Operadores: limitar sin escribir un contador

El stream trae conveniencias al estilo de las secuencias async:

```swift
// Solo las primeras 5 respuestas
for await batch in client.poll(MessagesEndpoint(channelID: "x")).first(5) {
    handle(batch)
}

// Mientras se cumpla una condición
let stream = client.poll(JobStatusEndpoint(id: "job_9"))
for await status in stream.while({ !$0.isComplete }) {
    updateProgress(status)
}
```

`first(_:)` y `while(_:)` te ahorran el típico `var count = 0` o el `break` manual, y se leen como lo que hacen.

## Estados observables

Internamente el stream modela su ciclo de vida con un enum, útil si quieres reflejar el estado en la UI:

```swift
public enum LongPollingState: Sendable, Equatable {
    case idle
    case polling
    case waiting(retryIn: TimeInterval)
    case cancelled
    case failed(NetworkError)
    case completed
}
```

Esto te permite, por ejemplo, mostrar un indicador "reconectando…" durante un `.waiting` sin inventarte máquinas de estado.

## Long polling vs. WebSockets: cuándo cada uno

El long polling **no** sustituye a WebSockets en todos los casos. Elige:

**Long polling (NetKit) cuando:**
- La frecuencia de cambios es de segundos, no milisegundos (estado de pedidos, jobs, notificaciones).
- Tu backend ya expone endpoints HTTP y no quieres operar infraestructura de sockets.
- Quieres atravesar proxies y balanceadores sin dolor (es HTTP normal).
- Te basta con flujo servidor→cliente.

**WebSockets cuando:**
- Necesitas latencia mínima y bidireccional real (chat en vivo a escala, juegos, colaboración en tiempo real).
- El volumen de mensajes hace caro abrir/cerrar conexiones HTTP repetidas.

Para el 80% de los "quiero que la pantalla se actualice sola cada pocos segundos", el long polling es más simple de operar y, con NetKit, igual de simple de escribir.

## Cuándo usar qué

- `.standard` → notificaciones, listas que se refrescan, lo genérico.
- `.realtime` → estados que el usuario está mirando fijamente (pago en curso, partida).
- `.long` → cambios poco frecuentes donde mantener la conexión abierta ahorra round-trips.
- `shouldContinuePolling` → para automáticamente cuando llega un estado terminal.
- `.first(n)` / `.while` → cuando sabes que el polling tiene un final natural.

## Siguiente paso

Hasta ahora movimos JSON pequeño. ¿Y cuando hay que subir una foto de 8 MB o bajar un PDF y **mostrar una barra de progreso** mientras tanto? Eso es el [artículo 6: subidas, descargas y progreso](06-transfers-progreso.md).
</content>
