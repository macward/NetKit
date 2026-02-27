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

    /// Allow the connection but log a warning.
    ///
    /// - Warning: **DEBUG ONLY** - Never use this in production builds.
    ///   This mode bypasses security and should only be used during development
    ///   to diagnose pinning issues. Consider using `#if DEBUG` to prevent
    ///   accidental use in release builds.
    ///
    /// Example safe usage:
    /// ```swift
    /// #if DEBUG
    /// let policy = basePolicy.withFailureAction(.allowWithWarning)
    /// #else
    /// let policy = basePolicy
    /// #endif
    /// ```
    case allowWithWarning
}

// MARK: - Security Policy

/// Configuration for SSL/TLS certificate pinning.
///
/// Use this to create a security policy that validates server certificates against
/// pinned public keys or certificates.
///
/// ## Quick Start
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
/// # Get raw public key in DER format
/// openssl s_client -connect api.example.com:443 2>/dev/null | \
/// openssl x509 -pubkey -noout | \
/// openssl pkey -pubin -outform der > publickey.der
///
/// # Or get base64-encoded SHA256 hash for verification
/// openssl s_client -connect api.example.com:443 2>/dev/null | \
/// openssl x509 -pubkey -noout | \
/// openssl pkey -pubin -outform der | \
/// openssl dgst -sha256 -binary | \
/// openssl enc -base64
/// ```
///
/// ## Extracting Full Certificates
///
/// To extract the full certificate in DER format (for certificate pinning):
/// ```bash
/// # Get certificate in DER format
/// openssl s_client -connect api.example.com:443 2>/dev/null | \
/// openssl x509 -outform der > certificate.der
/// ```
///
/// ## Loading Pin Data in Swift
///
/// ```swift
/// // From bundled file
/// let certURL = Bundle.main.url(forResource: "certificate", withExtension: "der")!
/// let certData = try Data(contentsOf: certURL)
///
/// // From base64 string (e.g., from config)
/// let base64Pin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
/// let pinData = Data(base64Encoded: base64Pin)!
/// ```
///
/// ## Certificate Rotation Best Practices
///
/// When rotating certificates, follow this procedure to avoid service disruption:
///
/// 1. **Before rotation**: Add the new certificate's public key to `fallbackKeys`
/// 2. **Deploy app update**: Release and allow time for user adoption
/// 3. **Rotate server certificate**: Switch to the new certificate on the server
/// 4. **After adoption**: Move new key to `publicKeys`, remove old key from both arrays
/// 5. **Deploy final update**: Release with cleaned-up pin configuration
///
/// Example:
/// ```swift
/// // Phase 1: Prepare for rotation
/// let policy = SecurityPolicy.publicKeyPinning(
///     hosts: ["api.example.com"],
///     publicKeys: [currentKeyData],
///     fallbackKeys: [newKeyData]  // Add new key as fallback
/// )
///
/// // Phase 2: After server rotation, clean up
/// let policy = SecurityPolicy.publicKeyPinning(
///     hosts: ["api.example.com"],
///     publicKeys: [newKeyData],   // New key is now primary
///     fallbackKeys: []            // Remove old key
/// )
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
    ///   - pinnedItems: The primary pinned items (keys or certificates). Must not be empty.
    ///   - fallbackItems: Backup items for certificate rotation.
    ///   - failureAction: Action to take on validation failure.
    ///   - validateCertificateChain: Whether to validate the certificate chain first.
    ///   - pinnedKeys: Structured keys (for SPKI hash support). Defaults to wrapping pinnedItems.
    ///   - fallbackKeys: Structured fallback keys. Defaults to wrapping fallbackItems.
    public init(
        mode: PinningMode,
        pinnedHosts: Set<String> = [],
        pinnedItems: [Data],
        fallbackItems: [Data] = [],
        failureAction: ValidationFailureAction = .reject,
        validateCertificateChain: Bool = true,
        pinnedKeys: [PinnedKey]? = nil,
        fallbackKeys: [PinnedKey]? = nil
    ) {
        precondition(
            !pinnedItems.isEmpty || !(pinnedKeys ?? []).isEmpty,
            "SecurityPolicy: pinnedItems or pinnedKeys cannot be empty. At least one pinned key or certificate is required."
        )
        self.mode = mode
        self.pinnedHosts = pinnedHosts
        self.pinnedItems = pinnedItems
        self.fallbackItems = fallbackItems
        self.failureAction = failureAction
        self.validateCertificateChain = validateCertificateChain
        // If pinnedKeys not provided, wrap pinnedItems as .der
        self.pinnedKeys = pinnedKeys ?? pinnedItems.map { .der($0) }
        self.fallbackKeys = fallbackKeys ?? fallbackItems.map { .der($0) }
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
    ///
    /// - Warning: Using `.allowWithWarning` bypasses security.
    ///   Only use for debugging in non-production builds.
    ///
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

    // MARK: - PinnedKey Support

    /// The pinned keys in structured format (for SPKI hash support).
    public let pinnedKeys: [PinnedKey]

    /// The fallback keys in structured format.
    public let fallbackKeys: [PinnedKey]

    /// All keys to validate against (primary + fallback).
    public var allPinnedKeys: [PinnedKey] {
        pinnedKeys + fallbackKeys
    }

    /// Creates a public key pinning policy with SPKI hash support.
    ///
    /// This is the recommended factory method when using SPKI hashes.
    ///
    /// - Parameters:
    ///   - hosts: Hosts to apply pinning to. Empty means all hosts.
    ///   - keys: The public keys to pin against (DER data or SPKI hashes).
    ///   - fallback: Backup keys for rotation.
    ///   - validateChain: Whether to validate the certificate chain first.
    /// - Returns: A configured security policy.
    public static func publicKeyPinning(
        hosts: Set<String> = [],
        keys: [PinnedKey],
        fallback: [PinnedKey] = [],
        validateChain: Bool = true
    ) -> SecurityPolicy {
        // Extract raw data for backwards compatibility
        let primaryData: [Data] = keys.compactMap { key in
            if case .der(let data) = key { return data }
            return nil
        }
        let fallbackData: [Data] = fallback.compactMap { key in
            if case .der(let data) = key { return data }
            return nil
        }

        return SecurityPolicy(
            mode: .publicKey,
            pinnedHosts: hosts,
            pinnedItems: primaryData.isEmpty ? [Data()] : primaryData,
            fallbackItems: fallbackData,
            failureAction: .reject,
            validateCertificateChain: validateChain,
            pinnedKeys: keys,
            fallbackKeys: fallback
        )
    }
}
