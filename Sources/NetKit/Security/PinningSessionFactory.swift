import Foundation
import ObjectiveC

// MARK: - Associated Object Key

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
/// The factory automatically manages the delegate's lifecycle by storing it as
/// an associated object on the URLSession. This ensures the delegate remains
/// alive for the duration of the session.
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
        // Keep delegate alive by storing it as an associated object on the session.
        // URLSession holds a weak reference to its delegate, so we need to retain it.
        objc_setAssociatedObject(session, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
        // Keep delegate alive by storing it as an associated object on the session.
        objc_setAssociatedObject(session, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return session
    }
}
