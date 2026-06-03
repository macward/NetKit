# Subidas, descargas y progreso

> Artículo 6 de la serie *NetKit en profundidad*.

Subir una foto de perfil, adjuntar un PDF, descargar un vídeo: en cuanto sales del JSON pequeño, aparecen dos necesidades que un `request()` normal no cubre bien. Una, **mostrar progreso** ("subiendo… 60%"). Dos, **poder cancelar** a mitad. NetKit modela las transferencias con esas dos cosas de primera clase, y manteniendo el mismo tipado fuerte de los endpoints.

## La forma del resultado: progreso + respuesta, por separado

Una subida o descarga devuelve un valor con dos partes claramente distintas:

```swift
public struct UploadResult<Response: Sendable>: Sendable {
    public let progress: TransferProgressStream   // eventos de progreso
    public let response: Task<Response, Error>     // el resultado final
}

public struct DownloadResult: Sendable {
    public let progress: TransferProgressStream
    public let response: Task<URL, Error>          // URL del archivo en disco
}
```

¿Por qué dividirlo? Porque son dos consumidores distintos: la UI quiere los eventos de progreso *mientras* ocurre la transferencia; el código de negocio quiere *el resultado*, que llega al final. Tenerlos en campos separados deja que cada uno avance a su ritmo, y que el `response` sea un `Task` significa que **cancelarlo cancela la transferencia**.

## Subir un archivo con barra de progreso

```swift
struct AvatarUploadEndpoint: Endpoint {
    var path: String { "/me/avatar" }
    var method: HTTPMethod { .post }
    typealias Response = UploadResponse
}

let upload = await client.upload(file: localFileURL, to: AvatarUploadEndpoint())

// 1. Consumir progreso mientras sube
for await progress in upload.progress {
    print(progress)  // CustomStringConvertible: "60% (614400/1024000)"
    progressBar.fractionCompleted = progress.fractionCompleted ?? 0
}

// 2. Esperar el resultado final
let response = try await upload.response.value
print("Subido con id \(response.fileId)")
```

El endpoint sigue siendo un `Endpoint` normal con su `Response` tipado: la subida no rompe el modelo, lo extiende.

## El evento de progreso

`TransferProgress` es rico: no solo el porcentaje, también velocidad y tiempo estimado, listo para una UI decente:

```swift
public struct TransferProgress: Sendable, Equatable {
    public let bytesCompleted: Int64
    public let totalBytes: Int64?
    public let isComplete: Bool
    public let estimatedTimeRemaining: TimeInterval?
    public let bytesPerSecond: Double?

    public var fractionCompleted: Double?  // 0.0 ... 1.0
}
```

`totalBytes` es opcional porque no siempre se conoce de antemano (descargas en streaming sin `Content-Length`); en ese caso `fractionCompleted` será `nil` y muestras un spinner indeterminado en vez de una barra.

## Multipart form data

Para formularios con campos y archivos mezclados (el clásico `multipart/form-data`), NetKit trae un builder:

```swift
public final class MultipartFormData: @unchecked Sendable {
    public init(boundary: String? = nil)
    public func append(value: String, name: String)
    public func append(data: Data, name: String, filename: String? = nil, mimeType: String? = nil)
    public func append(fileURL: URL, name: String, filename: String? = nil, mimeType: String? = nil) throws
}
```

```swift
let form = MultipartFormData()
form.append(value: "Mi documento", name: "title")
form.append(value: "private", name: "visibility")
try form.append(fileURL: pdfURL, name: "file")   // MIME inferido automáticamente

let upload = await client.upload(formData: form, to: DocumentUploadEndpoint())
for await progress in upload.progress { update(progress) }
let result = try await upload.response.value
```

Un detalle que ahorra bugs: el **MIME type se infiere de la extensión** (`.jpg`, `.png`, `.pdf`, `.docx`, `.mp4`…), con fallback a `application/octet-stream`. No tienes que mantener tu propia tabla de tipos.

## Descargar a disco

La descarga escribe directamente en una URL de destino y te devuelve esa URL al terminar (no carga el archivo entero en memoria):

```swift
struct ReportDownloadEndpoint: Endpoint {
    let id: String
    var path: String { "/reports/\(id)/pdf" }
    var method: HTTPMethod { .get }
    typealias Response = EmptyResponse  // el cuerpo es el archivo, no JSON
}

let destination = FileManager.default.temporaryDirectory.appendingPathComponent("report.pdf")
let download = await client.download(from: ReportDownloadEndpoint(id: "42"), to: destination)

for await progress in download.progress {
    progressBar.fractionCompleted = progress.fractionCompleted ?? 0
}

let fileURL = try await download.response.value
present(pdfAt: fileURL)
```

## Cancelación: es solo un `Task`

Como `response` es un `Task`, cancelar una transferencia es lo que ya sabes hacer con cualquier tarea de Swift:

```swift
let upload = await client.upload(file: bigFileURL, to: endpoint)

// más tarde, si el usuario pulsa "Cancelar":
upload.response.cancel()
```

No hay un API de cancelación especial que aprender. La cancelación estructurada de Swift se propaga y corta la transferencia.

## Por qué esto importa frente a hacerlo a mano

Con `URLSession` puro tendrías que implementar un `URLSessionTaskDelegate`, observar `progress` con KVO o callbacks, marshalar a `MainActor`, y atar la cancelación. Son decenas de líneas frágiles por cada transferencia. NetKit te lo da como un `AsyncStream` de progreso + un `Task` de resultado, ambos `Sendable`, listos para `for await` y `try await`.

## Cuándo usar qué

- `upload(file:to:)` → subir un único archivo ya en disco.
- `upload(formData:to:)` → formularios con varios campos y/o archivos (lo más común en APIs web).
- `download(from:to:)` → archivos grandes que no quieres en memoria (PDFs, vídeos, backups).
- Consumir `progress` → siempre que el usuario espere viendo la pantalla; ignóralo en transferencias de fondo pequeñas.
- `response.cancel()` → botón de cancelar, navegación que abandona la pantalla, timeouts de UX.

## Siguiente paso

Mover datos sensibles por la red abre una pregunta de seguridad: ¿cómo te aseguras de que hablas con tu servidor y no con un proxy que se hace pasar por él? Eso es el [artículo 7: certificate pinning](07-certificate-pinning.md).
</content>
