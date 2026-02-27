# Certificate Pinning

SSL/TLS certificate pinning protects your app against man-in-the-middle (MITM) attacks by validating that the server's certificate matches a known, trusted certificate or public key.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Pinning Modes](#pinning-modes)
- [Configuration Options](#configuration-options)
- [Extracting Pins](#extracting-pins)
- [Certificate Rotation](#certificate-rotation)
- [Debugging](#debugging)
- [Security Best Practices](#security-best-practices)
- [API Reference](#api-reference)
- [Troubleshooting](#troubleshooting)

## Overview

### What is Certificate Pinning?

By default, iOS/macOS trusts any certificate signed by a trusted Certificate Authority (CA). Certificate pinning adds an extra layer of security by requiring that the server present a specific certificate or public key that your app knows in advance.

### Why Use Certificate Pinning?

- **Prevent MITM Attacks**: Even if an attacker has a valid CA-signed certificate, they can't intercept your traffic
- **Protect Against Compromised CAs**: If a CA is compromised, your app remains secure
- **Detect Corporate Proxies**: Pinning fails if traffic goes through an intercepting proxy

### Architecture

NetKit's certificate pinning is implemented with zero impact on `NetworkClient`:

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────┐
│ SecurityPolicy  │ --> │ PinningSessionFactory │ --> │  URLSession │
└─────────────────┘     └──────────────────────┘     └──────┬──────┘
                                                            │
                                                            v
                                                    ┌───────────────┐
                                                    │ NetworkClient │
                                                    └───────────────┘
```

## Quick Start

### 1. Extract Your Server's Public Key

```bash
# Get the public key in DER format
openssl s_client -connect api.example.com:443 2>/dev/null | \
openssl x509 -pubkey -noout | \
openssl pkey -pubin -outform der > publickey.der
```

### 2. Add the Key to Your App Bundle

Add `publickey.der` to your Xcode project.

### 3. Configure Pinning

```swift
import NetKit

// Load the public key
let keyURL = Bundle.main.url(forResource: "publickey", withExtension: "der")!
let publicKeyData = try Data(contentsOf: keyURL)

// Create a security policy
let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com"],
    publicKeys: [publicKeyData]
)

// Create a pinned session
let session = PinningSessionFactory.createSession(policy: policy)

// Use with NetworkClient
let client = NetworkClient(
    environment: APIEnvironment(),
    session: session
)

// All requests now validate certificates
let user = try await client.request(GetUserEndpoint(id: "123"))
```

## Pinning Modes

### Public Key Pinning (Recommended)

Validates the server's public key. **Recommended** because it survives certificate renewal as long as the key pair remains the same.

```swift
let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com"],
    publicKeys: [publicKeyData],
    fallbackKeys: [backupKeyData]
)
```

**Advantages:**
- Survives certificate renewal (same key pair)
- Smaller pin data (just the key)
- More flexible for rotation

### Certificate Pinning

Validates the entire certificate. More strict but requires updating pins when certificates are renewed.

```swift
let policy = SecurityPolicy.certificatePinning(
    hosts: ["api.example.com"],
    certificates: [certificateData],
    fallbackCertificates: [backupCertData]
)
```

**Advantages:**
- Validates entire certificate identity
- Detects any certificate change

## Configuration Options

### SecurityPolicy Properties

| Property | Type | Description |
|----------|------|-------------|
| `mode` | `PinningMode` | `.publicKey` or `.certificate` |
| `pinnedHosts` | `Set<String>` | Hosts to apply pinning to (empty = all) |
| `pinnedItems` | `[Data]` | Primary pins (keys or certificates) |
| `fallbackItems` | `[Data]` | Backup pins for rotation |
| `failureAction` | `ValidationFailureAction` | `.reject` or `.allowWithWarning` |
| `validateCertificateChain` | `Bool` | Validate system chain first (default: true) |

### Host Filtering

```swift
// Pin specific hosts only
let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com", "cdn.example.com"],
    publicKeys: [keyData]
)

// Pin ALL hosts (empty set)
let policy = SecurityPolicy.publicKeyPinning(
    hosts: [],  // or omit parameter
    publicKeys: [keyData]
)
```

### Chain Validation

By default, the system certificate chain is validated before pinning. You can disable this for self-signed certificates:

```swift
let policy = SecurityPolicy.publicKeyPinning(
    publicKeys: [keyData],
    validateChain: false  // Skip system chain validation
)
```

## Extracting Pins

### Public Key (Recommended)

```bash
# From a live server
openssl s_client -connect api.example.com:443 2>/dev/null | \
openssl x509 -pubkey -noout | \
openssl pkey -pubin -outform der > publickey.der

# Get base64 hash for verification
openssl s_client -connect api.example.com:443 2>/dev/null | \
openssl x509 -pubkey -noout | \
openssl pkey -pubin -outform der | \
openssl dgst -sha256 -binary | \
openssl enc -base64
```

### Full Certificate

```bash
# From a live server
openssl s_client -connect api.example.com:443 2>/dev/null | \
openssl x509 -outform der > certificate.der

# From a PEM file
openssl x509 -in certificate.pem -outform der > certificate.der
```

### Loading in Swift

```swift
// From bundled file
let keyURL = Bundle.main.url(forResource: "publickey", withExtension: "der")!
let keyData = try Data(contentsOf: keyURL)

// From base64 string (e.g., from remote config)
let base64Pin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
let pinData = Data(base64Encoded: base64Pin)!

// From raw bytes
let pinData = Data([0x30, 0x82, 0x01, 0x22, ...])
```

## Certificate Rotation

Follow this procedure to rotate certificates without service disruption:

### Step 1: Prepare (Before Server Rotation)

Add the new certificate's public key as a fallback:

```swift
let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com"],
    publicKeys: [currentKeyData],      // Current production key
    fallbackKeys: [newKeyData]         // New key (backup)
)
```

### Step 2: Deploy App Update

Release the app with the updated policy. Allow time for user adoption.

### Step 3: Rotate Server Certificate

Switch the server to use the new certificate. Both old and new app versions will work.

### Step 4: Clean Up

After sufficient app adoption, update the pins:

```swift
let policy = SecurityPolicy.publicKeyPinning(
    hosts: ["api.example.com"],
    publicKeys: [newKeyData],          // New key is now primary
    fallbackKeys: []                   // Remove old key
)
```

### Step 5: Deploy Final Update

Release the cleaned-up configuration.

## Debugging

### Debug Mode (Development Only)

For troubleshooting pinning issues during development:

```swift
#if DEBUG
let policy = basePolicy.withFailureAction(.allowWithWarning)
#else
let policy = basePolicy
#endif
```

> **Warning**: Never use `.allowWithWarning` in production. It bypasses security.

### Checking Validated Hosts

```swift
let session = PinningSessionFactory.createSession(policy: policy)

// After making requests, check which hosts were validated
if let delegate = PinningSessionFactory.delegate(for: session) {
    print("Validated hosts: \(delegate.validatedHosts)")
    print("Is api.example.com validated? \(delegate.isHostValidated("api.example.com"))")
}
```

### Logging

Certificate pinning uses `os.Logger` with the subsystem "NetKit" and category "CertificatePinning". Enable in Console.app to see:

- `debug`: Successful validations, skipped hosts
- `info`: Fallback pin used (indicates rotation in progress)
- `warning`: Validation failures, extraction issues
- `error`: Rejected connections

## Security Best Practices

### Do

- Use **public key pinning** for easier certificate rotation
- Include **fallback keys** for rotation scenarios
- Test pinning in **development** before deploying
- **Monitor logs** for pinning failures in production
- **Plan for rotation** before certificates expire

### Don't

- Don't use `.allowWithWarning` in production
- Don't pin to intermediate or root CA certificates (pin leaf certificates)
- Don't forget to update pins before certificates expire
- Don't skip chain validation unless you have self-signed certificates

### Error Handling

```swift
do {
    let user = try await client.request(GetUserEndpoint(id: "123"))
} catch let error as URLError where error.code == .cancelled {
    // Certificate pinning failed - connection was rejected
    print("Security error: Certificate pinning validation failed")
} catch {
    print("Other error: \(error)")
}
```

## API Reference

### SecurityPolicy

```swift
// Factory methods
static func publicKeyPinning(
    hosts: Set<String> = [],
    publicKeys: [Data],
    fallbackKeys: [Data] = [],
    validateChain: Bool = true
) -> SecurityPolicy

static func certificatePinning(
    hosts: Set<String> = [],
    certificates: [Data],
    fallbackCertificates: [Data] = []
) -> SecurityPolicy

// Modifiers
func withFailureAction(_ action: ValidationFailureAction) -> SecurityPolicy

// Helpers
func shouldPin(host: String) -> Bool
var allPinnedItems: [Data] { get }
```

### PinningSessionFactory

```swift
// Create sessions
static func createSession(
    policy: SecurityPolicy,
    configuration: URLSessionConfiguration = .default
) -> URLSession

static func createSession(
    policy: SecurityPolicy,
    configuration: URLSessionConfiguration,
    delegateQueue: OperationQueue?
) -> URLSession

// Retrieve delegate
static func delegate(for session: URLSession) -> CertificatePinningDelegate?
```

### CertificatePinningDelegate

```swift
// Initialization
init(policy: SecurityPolicy)

// Public API
var validatedHosts: Set<String> { get }
func isHostValidated(_ host: String) -> Bool
```

### SecurityError

```swift
enum SecurityError: Error {
    case pinningValidationFailed(host: String)
    case certificateChainInvalid(host: String, underlyingError: Error?)
    case publicKeyExtractionFailed(host: String)
}
```

## Troubleshooting

### Pinning Always Fails

1. **Verify the pin data**: Ensure you're using DER format, not PEM
2. **Check the host**: Ensure the host in `pinnedHosts` matches exactly
3. **Validate the chain**: If using self-signed certs, set `validateChain: false`
4. **Check intermediate certs**: Make sure you're pinning the right certificate in the chain

### Pin Data Extraction Issues

```bash
# Verify your pin is valid DER
openssl pkey -pubin -inform der -in publickey.der -text -noout
```

### Connection Cancelled Immediately

This typically means pinning validation failed. Enable debug logging or temporarily use `.allowWithWarning` to diagnose.

### Works in Simulator, Fails on Device

Some corporate networks use intercepting proxies. Certificate pinning will correctly detect and reject these.

---

## Related Documentation

- [Authentication](authentication.md) - Combine pinning with auth interceptors
- [Testing](testing.md) - Test with MockNetworkClient (bypasses pinning)
- [Configuration](configuration.md) - Environment-specific pinning
