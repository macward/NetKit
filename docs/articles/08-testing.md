# Testing sin dolor

> Artículo 8 (final) de la serie *NetKit en profundidad*.

Una capa de red que no se puede testear bien es una bomba de relojería: cada bug se descubre en producción, contra un servidor real, de forma intermitente. El test de un servicio que llama a la red **no debería tocar la red**: debe ser rápido, determinista y ejecutarse en CI sin conexión.

NetKit trae esto resuelto de fábrica con `MockNetworkClient`, y el secreto está en una decisión que tomamos en el [artículo 2](02-primeros-pasos-endpoints.md): programar contra un **protocolo**.

## La base: inyectar `NetworkClientProtocol`

Tu servicio no debe depender de `NetworkClient` (la implementación), sino de `NetworkClientProtocol` (el contrato). Así puedes pasarle el real en producción y el mock en tests:

```swift
final class UserService {
    private let client: NetworkClientProtocol

    init(client: NetworkClientProtocol) {
        self.client = client
    }

    func getUser(id: String) async throws -> User {
        try await client.request(GetUserEndpoint(id: id))
    }
}

// Producción
let service = UserService(client: NetworkClient(environment: APIEnvironment()))

// Tests
let service = UserService(client: MockNetworkClient())
```

Tanto `NetworkClient` como `MockNetworkClient` conforman `NetworkClientProtocol`, así que son intercambiables. Tu servicio no nota la diferencia.

## Stubbear una respuesta

`MockNetworkClient` es un **actor**, así que todas sus operaciones son `async`. Le dices "cuando te pidan este endpoint, devuelve esto":

```swift
import Testing
@testable import NetKit

@Test("getUser devuelve el usuario stubbeado")
func getUserReturnsStubbedUser() async throws {
    let mock = MockNetworkClient()
    let service = UserService(client: mock)

    await mock.stub(GetUserEndpoint.self) { endpoint in
        User(id: endpoint.id, name: "John", email: "john@example.com")
    }

    let user = try await service.getUser(id: "123")

    #expect(user.name == "John")
    let calls = await mock.callCount(for: GetUserEndpoint.self)
    #expect(calls == 1)
}
```

Fíjate en que el closure recibe el **endpoint real**, así que puedes generar la respuesta a partir de sus propiedades (`endpoint.id`). El mock no es "devuelve siempre lo mismo": es "devuelve en función de lo que te pidieron".

## Stubbear errores

```swift
@Test("getUser propaga notFound")
func getUserPropagatesNotFound() async throws {
    let mock = MockNetworkClient()
    let service = UserService(client: mock)

    await mock.stubError(GetUserEndpoint.self, error: .notFound())

    await #expect(throws: NetworkError.self) {
        try await service.getUser(id: "invalid")
    }
}
```

Como el `NetworkError` es `Equatable` (lo vimos en el [artículo 1](01-por-que-netkit-vs-alamofire.md)), puedes afinar el assert sobre el `kind` concreto:

```swift
do {
    _ = try await service.getUser(id: "invalid")
    Issue.record("Se esperaba un error")
} catch let error as NetworkError {
    #expect(error.kind == .notFound)
}
```

## Simular latencia

Para testear spinners, timeouts y estados de carga, stubbea con delay:

```swift
@Test("getUser respeta el delay del mock")
func getUserHonorsDelay() async throws {
    let mock = MockNetworkClient()
    let service = UserService(client: mock)

    await mock.stub(GetUserEndpoint.self, delay: 0.5) { _ in
        User(id: "1", name: "John", email: "john@example.com")
    }

    let start = ContinuousClock.now
    _ = try await service.getUser(id: "1")
    #expect(start.duration(to: .now) >= .milliseconds(500))
}
```

## Secuencias: el truco para testear polling y reintentos

Aquí es donde el mock brilla. Una sola respuesta no basta para probar long polling o lógica de retry, porque esos hacen **varias llamadas**. `stubSequence` devuelve respuestas distintas en orden:

```swift
await mock.stubSequence(MessagesEndpoint.self, responses: [
    [Message(id: "1")],
    [Message(id: "1"), Message(id: "2")],
    [Message(id: "1"), Message(id: "2"), Message(id: "3")]
])
```

La primera llamada devuelve un mensaje, la segunda dos, la tercera tres. Justo lo que necesitas para verificar que tu consumidor de `poll(_:)` acumula bien.

Y puedes **mezclar éxitos y fallos** para testear que tu retry hace lo correcto:

```swift
await mock.stubSequence(GetUserEndpoint.self, sequence: [
    .success(User(id: "1", name: "John", email: "j@x.com")),
    .failure(.timeout()),
    .success(User(id: "1", name: "John", email: "j@x.com"))
])
```

Esto te deja escribir un test que afirma: "ante un timeout en medio, mi política de reintento vuelve a intentar y acaba teniendo éxito". Sin tocar la red, sin esperas reales, determinista.

## Stubbear transfers con progreso

Las subidas y descargas (del [artículo 6](06-transfers-progreso.md)) también se stubbean, **incluyendo los eventos de progreso**:

```swift
await mock.stubUpload(
    AvatarUploadEndpoint.self,
    progressSequence: [
        TransferProgress(bytesCompleted: 500, totalBytes: 1000),
        TransferProgress(bytesCompleted: 1000, totalBytes: 1000, isComplete: true)
    ]
) { _ in
    UploadResponse(fileId: "123", size: 1000)
}
```

Así puedes testear que tu barra de progreso reacciona correctamente, sin subir nada de verdad.

## Verificación: ¿se llamó como esperaba?

El mock registra el historial de llamadas, para que tus tests verifiquen interacciones, no solo resultados:

```swift
let count = await mock.callCount(for: GetUserEndpoint.self)   // cuántas veces
let wasCalled = await mock.wasCalled(GetUserEndpoint.self)    // si se llamó
let endpoints = await mock.calledEndpoints(of: GetUserEndpoint.self)  // los endpoints reales

// Inspeccionar los argumentos con los que se llamó:
#expect(endpoints.first?.id == "123")

await mock.reset()  // limpia stubs e historial entre tests
```

`calledEndpoints` es especialmente útil: te devuelve los structs de endpoint reales, así que puedes afirmar que se llamó con el `id`, la `page` o el `body` correctos.

## Qué pasa si no hay stub

Si tu servicio llama a un endpoint que no stubbeaste, el mock lanza un `MockError.noStubConfigured`, y si una secuencia se agota, `MockError.sequenceExhausted`. Es decir: un test que toca un endpoint inesperado **falla en vez de devolver basura silenciosamente**. Eso es exactamente lo que quieres —los tests te avisan de llamadas que no esperabas.

## El círculo completo

Reúne todo lo de la serie en un test realista:

```swift
@Test("El flujo de búsqueda pagina y acumula")
func searchPaginates() async throws {
    let mock = MockNetworkClient()
    let service = SearchService(client: mock)

    await mock.stub(SearchUsersEndpoint.self) { endpoint in
        SearchResults(page: endpoint.page, items: makeUsers(page: endpoint.page))
    }

    let firstPage = try await service.search(query: "john", page: 1)
    let secondPage = try await service.search(query: "john", page: 2)

    #expect(firstPage.page == 1)
    #expect(secondPage.page == 2)

    let calls = await mock.calledEndpoints(of: SearchUsersEndpoint.self)
    #expect(calls.map(\.page) == [1, 2])
    #expect(calls.allSatisfy { $0.query == "john" })
}
```

Rápido, determinista, sin red. Eso es testear una capa de red bien.

> **¿Usas XCTest en vez de Swift Testing?** Funciona igual: la API del mock es la misma, solo cambian los asserts (`XCTAssertEqual` en lugar de `#expect`). NetKit no te ata a un framework de tests.

## Cierre de la serie

Has recorrido NetKit de punta a punta:

1. **Por qué** elegirlo frente a Alamofire —tipado fuerte, Swift 6 nativo, cero dependencias.
2. **Endpoints** type-safe como única fuente de verdad.
3. **Auth e interceptors** con refresh coordinado sin carreras.
4. **Caché, retry y dedupe** que respetan HTTP y no hacen trabajo de más.
5. **Long polling** como `AsyncSequence`.
6. **Transfers** con progreso y cancelación estructurada.
7. **Certificate pinning** con rotación sin downtime.
8. **Testing** rápido y determinista con `MockNetworkClient`.

La idea de fondo, repetida en cada capa: una superficie pequeña, tipada y diseñada para Swift moderno cunde más que un framework gigante que lo cubre todo. Si tu proyecto es nuevo y apunta a iOS 18+ / macOS 15+, NetKit te da exactamente lo que necesitas —y nada más.
</content>
