import CryptoKit
import Foundation

/// A pinned public key or certificate for certificate pinning validation.
///
/// Supports two formats:
/// - **Raw DER data**: The full public key or certificate in DER format
/// - **SPKI SHA256 hash**: The base64-encoded SHA256 hash of the Subject Public Key Info
///
/// SPKI hashes are more convenient because they're widely used and easy to obtain:
/// ```bash
/// # Get SPKI hash for a domain
/// openssl s_client -connect api.example.com:443 2>/dev/null | \
/// openssl x509 -pubkey -noout | \
/// openssl pkey -pubin -outform der | \
/// openssl dgst -sha256 -binary | \
/// openssl enc -base64
/// ```
///
/// ## Example Usage
///
/// ```swift
/// // Using SPKI hash (recommended for convenience)
/// let pin = PinnedKey.spkiSHA256("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
///
/// // Using raw DER data
/// let pin = PinnedKey.der(publicKeyData)
///
/// // Create a security policy
/// let policy = SecurityPolicy.publicKeyPinning(
///     hosts: ["api.example.com"],
///     publicKeys: [pin],
///     fallbackKeys: [backupPin]
/// )
/// ```
public enum PinnedKey: Sendable, Equatable, Hashable {
    /// Raw DER-encoded public key or certificate data.
    case der(Data)

    /// Base64-encoded SHA256 hash of the Subject Public Key Info (SPKI).
    ///
    /// This is the standard format used by browsers and security tools.
    /// The hash is computed over the DER-encoded public key.
    case spkiSHA256(String)

    // MARK: - Validation

    /// Checks if this pinned key matches the given public key data.
    /// - Parameter publicKeyData: The raw DER-encoded public key from the certificate.
    /// - Returns: `true` if the key matches this pin.
    public func matches(publicKeyData: Data) -> Bool {
        switch self {
        case .der(let pinnedData):
            return pinnedData == publicKeyData

        case .spkiSHA256(let expectedHash):
            let actualHash: String = Self.computeSPKIHash(from: publicKeyData)
            return actualHash == expectedHash
        }
    }

    /// Checks if this pinned key matches the given certificate data.
    /// - Parameter certificateData: The raw DER-encoded certificate.
    /// - Returns: `true` if the certificate matches this pin.
    public func matches(certificateData: Data) -> Bool {
        switch self {
        case .der(let pinnedData):
            return pinnedData == certificateData

        case .spkiSHA256:
            // SPKI hash is for public keys, not full certificates
            // For certificates, we need to extract the public key first
            return false
        }
    }

    // MARK: - Hash Computation

    /// Computes the SPKI SHA256 hash from raw public key data.
    /// - Parameter publicKeyData: The raw DER-encoded public key.
    /// - Returns: The base64-encoded SHA256 hash.
    public static func computeSPKIHash(from publicKeyData: Data) -> String {
        let hash: SHA256.Digest = SHA256.hash(data: publicKeyData)
        return Data(hash).base64EncodedString()
    }
}

// MARK: - Convenience Initializers

public extension PinnedKey {
    /// Creates a pinned key from a base64-encoded DER string.
    /// - Parameter base64: The base64-encoded DER data.
    /// - Returns: A pinned key, or nil if the base64 is invalid.
    static func derBase64(_ base64: String) -> PinnedKey? {
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return .der(data)
    }
}
