import Foundation
import ObjectiveC

// MARK: - Associated Object Key

// Associated object key - only its memory address is used as an identifier.
// The value itself is never read or written concurrently, making this safe.
private nonisolated(unsafe) var delegateKey: UInt8 = 0

// MARK: - Pinning Session Factory

/// Factory for creating URLSessions configured with certificate pinning.
///
/// Use this factory to create a URLSession with certificate pinning that can be
/// passed to `NetworkClient`.
///
/// ## Example
///
/// ```swift
/// // Create a security policy
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
/// let client = NetworkClient(
///     environment: ProductionEnvironment(),
///     session: session
/// )
/// ```
///
/// ## Delegate Lifecycle
///
/// The factory manages the delegate's lifecycle by storing it as an associated
/// object on the URLSession. This ensures the delegate remains alive for the
/// session's duration. When you're done with the session, call
/// `session.finishTasksAndInvalidate()` or `session.invalidateAndCancel()`
/// to properly clean up resources.
///
/// ## Important
///
/// Always invalidate sessions when done to prevent memory leaks:
/// ```swift
/// defer { session.finishTasksAndInvalidate() }
/// ```
public enum PinningSessionFactory {
    /// Creates a URLSession configured with certificate pinning.
    ///
    /// The returned session will validate server certificates against the pinned
    /// keys or certificates defined in the security policy during the TLS handshake.
    ///
    /// - Parameters:
    ///   - policy: The security policy defining pinning configuration.
    ///   - configuration: The URLSession configuration to use. Defaults to `.default`.
    /// - Returns: A URLSession configured with certificate pinning.
    public static func createSession(
        policy: SecurityPolicy,
        configuration: URLSessionConfiguration = .default
    ) -> URLSession {
        let delegate: CertificatePinningDelegate = CertificatePinningDelegate(policy: policy)
        let session: URLSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        // Store delegate as associated object to ensure it stays alive.
        // URLSession retains its delegate, but we also store it here to make
        // the ownership explicit and allow retrieval if needed.
        objc_setAssociatedObject(
            session,
            &delegateKey,
            delegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return session
    }

    /// Creates a URLSession configured with certificate pinning and a custom delegate queue.
    ///
    /// - Parameters:
    ///   - policy: The security policy defining pinning configuration.
    ///   - configuration: The URLSession configuration to use.
    ///   - delegateQueue: The operation queue for delegate callbacks.
    /// - Returns: A URLSession configured with certificate pinning.
    public static func createSession(
        policy: SecurityPolicy,
        configuration: URLSessionConfiguration,
        delegateQueue: OperationQueue?
    ) -> URLSession {
        let delegate: CertificatePinningDelegate = CertificatePinningDelegate(policy: policy)
        let session: URLSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        // Store delegate as associated object to ensure it stays alive.
        objc_setAssociatedObject(
            session,
            &delegateKey,
            delegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return session
    }

    /// Retrieves the pinning delegate from a session created by this factory.
    ///
    /// - Parameter session: A URLSession created by `createSession(policy:)`.
    /// - Returns: The `CertificatePinningDelegate` if found, nil otherwise.
    public static func delegate(for session: URLSession) -> CertificatePinningDelegate? {
        objc_getAssociatedObject(session, &delegateKey) as? CertificatePinningDelegate
    }
}
