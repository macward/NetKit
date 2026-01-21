import Foundation
import Security
import os

// MARK: - Certificate Pinning Delegate

/// A URLSession delegate that performs certificate pinning validation.
///
/// This delegate validates server certificates against pinned public keys or certificates
/// during the TLS handshake. Use it with `PinningSessionFactory` to create a configured
/// URLSession.
///
/// ## Example
///
/// ```swift
/// let policy = SecurityPolicy.publicKeyPinning(
///     hosts: ["api.example.com"],
///     publicKeys: [publicKeyData]
/// )
/// let delegate = CertificatePinningDelegate(policy: policy)
/// let session = URLSession(
///     configuration: .default,
///     delegate: delegate,
///     delegateQueue: nil
/// )
/// ```
///
/// ## Thread Safety
///
/// This delegate is thread-safe and can be used with concurrent requests.
public final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let policy: SecurityPolicy
    private let state: OSAllocatedUnfairLock<DelegateState>
    private let logger: Logger

    // MARK: - State

    private struct DelegateState: Sendable {
        var validatedHosts: Set<String> = []
    }

    // MARK: - Initialization

    /// Creates a certificate pinning delegate with the given policy.
    /// - Parameter policy: The security policy to enforce.
    public init(policy: SecurityPolicy) {
        self.policy = policy
        self.state = OSAllocatedUnfairLock(initialState: DelegateState())
        self.logger = Logger(subsystem: "NetKit", category: "CertificatePinning")
        super.init()
    }

    // MARK: - URLSessionDelegate

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host: String = challenge.protectionSpace.host

        // Skip pinning for hosts not in the pinned list
        guard policy.shouldPin(host: host) else {
            logger.debug("Skipping pinning for non-pinned host: \(host)")
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Validate certificate chain first if required
        if policy.validateCertificateChain {
            var error: CFError?
            let isChainValid: Bool = SecTrustEvaluateWithError(serverTrust, &error)

            if !isChainValid {
                logger.warning("Certificate chain validation failed for \(host)")
                handleValidationFailure(
                    host: host,
                    error: .certificateChainInvalid(host: host, underlyingError: error),
                    completionHandler: completionHandler
                )
                return
            }
        }

        // Perform pinning validation
        let validationResult: PinningValidationResult = validatePinning(serverTrust: serverTrust, host: host)

        switch validationResult {
        case .success:
            state.withLock { $0.validatedHosts.insert(host) }
            let credential: URLCredential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)

        case .failure(let error):
            handleValidationFailure(host: host, error: error, completionHandler: completionHandler)
        }
    }

    // MARK: - Pinning Validation

    private enum PinningValidationResult {
        case success
        case failure(SecurityError)
    }

    private func validatePinning(serverTrust: SecTrust, host: String) -> PinningValidationResult {
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !certificateChain.isEmpty else {
            logger.warning("No certificates found in server trust for \(host)")
            return .failure(.pinningValidationFailed(host: host))
        }

        let allPinnedItems: [Data] = policy.allPinnedItems

        for certificate in certificateChain {
            let itemToCompare: Data?

            switch policy.mode {
            case .publicKey:
                itemToCompare = extractPublicKey(from: certificate)
                if itemToCompare == nil {
                    logger.warning("Failed to extract public key from certificate for \(host)")
                }

            case .certificate:
                itemToCompare = SecCertificateCopyData(certificate) as Data
            }

            guard let item = itemToCompare else {
                continue
            }

            if allPinnedItems.contains(item) {
                let isPrimary: Bool = policy.pinnedItems.contains(item)
                if isPrimary {
                    logger.debug("Certificate pinning succeeded for \(host) (primary pin)")
                } else {
                    logger.info("Certificate pinning succeeded for \(host) (fallback pin)")
                }
                return .success
            }
        }

        logger.warning("Certificate pinning failed for \(host) - no matching pins found")
        return .failure(.pinningValidationFailed(host: host))
    }

    private func extractPublicKey(from certificate: SecCertificate) -> Data? {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }

        return publicKeyData
    }

    // MARK: - Failure Handling

    private func handleValidationFailure(
        host: String,
        error: SecurityError,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch policy.failureAction {
        case .reject:
            logger.error("Certificate pinning rejected connection to \(host): \(error.localizedDescription)")
            completionHandler(.cancelAuthenticationChallenge, nil)

        case .allowWithWarning:
            logger.warning("Certificate pinning failed for \(host) but allowing connection (debug mode): \(error.localizedDescription)")
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
