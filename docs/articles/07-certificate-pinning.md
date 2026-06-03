# Seguridad: certificate pinning

> Artículo 7 de la serie *NetKit en profundidad*.

Por defecto, iOS y macOS confían en cualquier certificado firmado por una Autoridad de Certificación (CA) reconocida. Suena razonable hasta que piensas en el escenario que esto deja abierto: si un atacante consigue un certificado válido (CA comprometida, proxy corporativo, dispositivo con un CA instalado), puede ponerse en medio de tu conexión TLS y leer todo lo que viaja. Es el ataque **man-in-the-middle (MITM)**.

El **certificate pinning** cierra esa puerta: tu app exige que el servidor presente un certificado o clave pública **que ella ya conoce de antemano**. Si no coincide —aunque el certificado sea técnicamente "válido"— la conexión se rechaza.

NetKit implementa pinning con una propiedad de diseño importante: **cero impacto en `NetworkClient`**. El pinning vive en la `URLSession`, no en el cliente.

## La arquitectura en una línea

```
SecurityPolicy → PinningSessionFactory → URLSession → NetworkClient
```

Defines una política, fabricas una sesión pinneada con ella, y se la pasas al `NetworkClient` como cualquier otra sesión. El cliente no sabe ni le importa que está pinneado.

## Quick start

### 1. Extrae la clave pública de tu servidor

```bash
openssl s_client -connect api.example.com:443 2>/dev/null | \
openssl x509 -pubkey -noout | \
openssl pkey -pubin -outform der > publickey.der
```

### 2. Añade `publickey.der` al bundle de la app

### 3. Configura el pinning

```swift
import NetKit

let keyURL = Bundle.main.url(forResource: "publickey", withExtension: "der")!
let publicKeyData = try Data(contentsOf: keyURL)

let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com"],
    publicKeys: [publicKeyData]
)

let session = PinningSessionFactory.createSession(policy: policy)

let client = NetworkClient(
    environment: APIEnvironment(),
    session: session
)

// Todas las requests ahora validan el certificado
let user = try await client.request(GetUserEndpoint(id: "123"))
```

Eso es todo. El resto de tu código —endpoints, interceptors, caché— no cambia.

## Dos modos: clave pública vs. certificado

### Pinning de clave pública (recomendado)

Valida la **clave pública** del servidor. Es el recomendado porque **sobrevive a la renovación del certificado**: mientras el par de claves no cambie, renovar el certificado no rompe tu app.

```swift
let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com"],
    publicKeys: [publicKeyData],
    fallbackKeys: [backupKeyData]
)
```

### Pinning de certificado completo

Valida el certificado entero. Más estricto, pero te obliga a actualizar los pins cada vez que renuevas el certificado.

```swift
let policy = SecurityPolicy.certificatePinning(
    hosts: ["api.example.com"],
    certificates: [certificateData],
    fallbackCertificates: [backupCertData]
)
```

En la práctica: **usa pinning de clave pública** salvo que tengas una razón concreta para lo contrario.

## El problema real del pinning: la rotación

Mucha gente le tiene miedo al pinning por una historia de terror: "el certificado caducó, la app dejó de conectar y hubo que sacar una release de emergencia". Eso pasa cuando rotas mal. NetKit resuelve la rotación con **fallback keys** y un procedimiento de cuatro pasos sin downtime:

**Paso 1 — Prepara (antes de rotar el servidor).** Añade la clave nueva como fallback en la app:

```swift
let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com"],
    publicKeys: [currentKeyData],   // clave actual de producción
    fallbackKeys: [newKeyData]      // clave nueva (de respaldo)
)
```

**Paso 2 — Despliega la app** con esa política y da tiempo a que los usuarios actualicen.

**Paso 3 — Rota el certificado del servidor.** Como las apps ya aceptan la clave nueva como fallback, tanto las versiones viejas como las nuevas siguen funcionando.

**Paso 4 — Limpia.** En una release posterior, promueve la nueva a primaria y quita la vieja:

```swift
let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com"],
    publicKeys: [newKeyData],
    fallbackKeys: []
)
```

La clave: **el fallback se despliega antes que la rotación del servidor**. Nunca hay un momento en que las apps en producción no conozcan la clave activa.

## Debug sin pegarte un tiro en el pie

Durante el desarrollo a veces necesitas ver qué pasa sin que la conexión muera. Para eso está `.allowWithWarning`, **encerrado en `#if DEBUG`**:

```swift
#if DEBUG
let policy = basePolicy.withFailureAction(.allowWithWarning)
#else
let policy = basePolicy
#endif
```

> ⚠️ **Nunca** uses `.allowWithWarning` en producción: anula la seguridad que acabas de montar.

Y puedes inspeccionar qué hosts se validaron:

```swift
if let delegate = PinningSessionFactory.delegate(for: session) {
    print("Hosts validados: \(delegate.validatedHosts)")
    print("¿api.example.com validado? \(delegate.isHostValidated("api.example.com"))")
}
```

El pinning loguea con `os.Logger` (subsistema "NetKit", categoría "CertificatePinning"), así que en Console.app ves validaciones correctas, uso de fallback (señal de que una rotación está en curso) y rechazos.

## Manejo de errores

Cuando el pinning falla, la conexión se cancela:

```swift
do {
    let user = try await client.request(GetUserEndpoint(id: "123"))
} catch let error as URLError where error.code == .cancelled {
    print("Error de seguridad: la validación de pinning falló")
} catch {
    print("Otro error: \(error)")
}
```

## Buenas prácticas (las que importan)

**Sí:**
- Usa **pinning de clave pública** para rotaciones indoloras.
- Incluye **fallback keys** siempre que tengas pinning.
- Prueba el pinning **en desarrollo** antes de desplegar.
- **Monitoriza los logs** de fallos en producción.
- **Planifica la rotación** antes de que el certificado caduque.

**No:**
- No uses `.allowWithWarning` en producción.
- No pinnees certificados intermedios o raíz: pinnea el **leaf** (el del servidor).
- No te olvides de actualizar pins antes de que caduquen.
- No desactives la validación de cadena salvo con certificados self-signed.

## Cuándo usar pinning (y cuándo no)

**Úsalo cuando:**
- Manejas datos sensibles (financieros, salud, credenciales).
- Tu app es objetivo plausible de interceptación (banca, mensajería).
- Cumplimiento normativo te lo exige.

**Quizá no lo necesites cuando:**
- Es un prototipo o app interna de bajo riesgo.
- No tienes proceso para gestionar la rotación de certificados (el pinning mal mantenido es peor que no tenerlo: te tira la app en producción).

El pinning es una herramienta potente con un coste operativo real. NetKit baja ese coste con los fallbacks y el procedimiento de rotación, pero la decisión de adoptarlo sigue siendo tuya.

## Siguiente paso

Toda esta funcionalidad —endpoints, auth, caché, transfers, pinning— no sirve de nada si no puedes testearla rápido y sin red. El último artículo cierra el círculo: [testing sin dolor con `MockNetworkClient`](08-testing.md).
</content>
