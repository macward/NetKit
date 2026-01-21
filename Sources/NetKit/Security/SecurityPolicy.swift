import Foundation

// MARK: - Pinning Mode

/// The type of certificate pinning to perform.
public enum PinningMode: Sendable, Equatable {
    /// Pin to the public key of certificates.
    /// Recommended: survives certificate renewal as long as the key pair remains the same.
    case publicKey

    /// Pin to the full certificate.
    /// More strict but requires updating pins when certificates are renewed.
    case certificate
}

// MARK: - Validation Failure Action

/// How to handle certificate pinning validation failures.
public enum ValidationFailureAction: Sendable, Equatable {
    /// Reject the connection when pinning fails. This is the secure default.
    case reject

    /// Allow the connection but log a warning. Use only for debugging.
    case allowWithWarning
}

// MARK: - Security Policy

/// Configuration for SSL/TLS certificate pinning.
///
/// Use this to create a security policy that validates server certificates against
/// pinned public keys or certificates.
///
/// ## Example
///
/// ```swift
/// // Public key pinning (recommended)
/// let policy = SecurityPolicy.publicKeyPinning(
///     hosts: ["api.example.com"],
///     publicKeys: [serverPublicKeyData],
///     fallbackKeys: [backupKeyData]
/// )
///
/// // Create a session with pinning
/// let session = PinningSessionFactory.createSession(policy: policy)
///
/// // Use with NetworkClient
/// let client = NetworkClient(environment: env, session: session)
/// ```
///
/// ## Extracting Public Keys
///
/// To extract the public key from a server certificate using OpenSSL:
/// ```bash
/// openssl s_client -connect api.example.com:443 | \
/// openssl x509 -pubkey -noout | \
/// openssl pkey -pubin -outform der | \
/// openssl dgst -sha256 -binary | \
/// openssl enc -base64
/// ```
public struct SecurityPolicy: Sendable, Equatable {
    /// The pinning mode to use.
    public let mode: PinningMode

    /// The hosts to apply pinning to. If empty, pinning applies to all hosts.
    public let pinnedHosts: Set<String>

    /// The pinned public keys or certificates as raw Data.
    public let pinnedItems: [Data]

    /// Fallback items to allow certificate rotation without downtime.
    public let fallbackItems: [Data]

    /// What to do when pinning validation fails.
    public let failureAction: ValidationFailureAction

    /// Whether to validate the system certificate chain before pinning.
    public let validateCertificateChain: Bool

    // MARK: - Initializer

    /// Creates a security policy with full configuration.
    /// - Parameters:
    ///   - mode: The pinning mode (public key or certificate).
    ///   - pinnedHosts: Hosts to apply pinning to. Empty means all hosts.
    ///   - pinnedItems: The primary pinned items (keys or certificates).
    ///   - fallbackItems: Backup items for certificate rotation.
    ///   - failureAction: Action to take on validation failure.
    ///   - validateCertificateChain: Whether to validate the certificate chain first.
    public init(
        mode: PinningMode,
        pinnedHosts: Set<String> = [],
        pinnedItems: [Data],
        fallbackItems: [Data] = [],
        failureAction: ValidationFailureAction = .reject,
        validateCertificateChain: Bool = true
    ) {
        precondition(!pinnedItems.isEmpty, "pinnedItems cannot be empty - at least one pinned key or certificate is required")
        self.mode = mode
        self.pinnedHosts = pinnedHosts
        self.pinnedItems = pinnedItems
        self.fallbackItems = fallbackItems
        self.failureAction = failureAction
        self.validateCertificateChain = validateCertificateChain
    }

    // MARK: - Factory Methods

    /// Creates a public key pinning policy.
    ///
    /// Public key pinning is recommended because it survives certificate renewal
    /// as long as the same key pair is used.
    ///
    /// - Parameters:
    ///   - hosts: Hosts to apply pinning to. Empty means all hosts.
    ///   - publicKeys: The public keys to pin against (as raw DER-encoded Data).
    ///   - fallbackKeys: Backup keys for rotation.
    ///   - validateChain: Whether to validate the certificate chain first.
    /// - Returns: A configured security policy.
    public static func publicKeyPinning(
        hosts: Set<String> = [],
        publicKeys: [Data],
        fallbackKeys: [Data] = [],
        validateChain: Bool = true
    ) -> SecurityPolicy {
        SecurityPolicy(
            mode: .publicKey,
            pinnedHosts: hosts,
            pinnedItems: publicKeys,
            fallbackItems: fallbackKeys,
            failureAction: .reject,
            validateCertificateChain: validateChain
        )
    }

    /// Creates a certificate pinning policy.
    ///
    /// Certificate pinning is more strict but requires updating pins when
    /// certificates are renewed.
    ///
    /// - Parameters:
    ///   - hosts: Hosts to apply pinning to. Empty means all hosts.
    ///   - certificates: The certificates to pin against (as raw DER-encoded Data).
    ///   - fallbackCertificates: Backup certificates for rotation.
    /// - Returns: A configured security policy.
    public static func certificatePinning(
        hosts: Set<String> = [],
        certificates: [Data],
        fallbackCertificates: [Data] = []
    ) -> SecurityPolicy {
        SecurityPolicy(
            mode: .certificate,
            pinnedHosts: hosts,
            pinnedItems: certificates,
            fallbackItems: fallbackCertificates,
            failureAction: .reject,
            validateCertificateChain: true
        )
    }

    // MARK: - Modifiers

    /// Returns a copy of this policy with a different failure action.
    /// - Parameter action: The new failure action.
    /// - Returns: A modified security policy.
    public func withFailureAction(_ action: ValidationFailureAction) -> SecurityPolicy {
        SecurityPolicy(
            mode: mode,
            pinnedHosts: pinnedHosts,
            pinnedItems: pinnedItems,
            fallbackItems: fallbackItems,
            failureAction: action,
            validateCertificateChain: validateCertificateChain
        )
    }

    // MARK: - Validation Helpers

    /// Checks if pinning should be applied to the given host.
    /// - Parameter host: The host to check.
    /// - Returns: `true` if pinning should be applied.
    public func shouldPin(host: String) -> Bool {
        pinnedHosts.isEmpty || pinnedHosts.contains(host)
    }

    /// All items to validate against (primary + fallback).
    public var allPinnedItems: [Data] {
        pinnedItems + fallbackItems
    }
}
