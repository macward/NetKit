import Foundation

/// Errors related to certificate pinning and security validation.
public enum SecurityError: Error, Sendable {
    /// Certificate pinning validation failed - the server certificate did not match any pinned keys.
    case pinningValidationFailed(host: String)

    /// The certificate chain could not be validated by the system.
    case certificateChainInvalid(host: String, underlyingError: (any Error)?)

    /// The public key could not be extracted from the server certificate.
    case publicKeyExtractionFailed(host: String)
}

// MARK: - LocalizedError

extension SecurityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pinningValidationFailed(let host):
            return "Certificate pinning validation failed for host: \(host)"
        case .certificateChainInvalid(let host, _):
            return "Certificate chain validation failed for host: \(host)"
        case .publicKeyExtractionFailed(let host):
            return "Failed to extract public key from certificate for host: \(host)"
        }
    }

    public var failureReason: String? {
        switch self {
        case .pinningValidationFailed:
            return "The server's certificate or public key did not match any of the pinned values."
        case .certificateChainInvalid(_, let error):
            if let error {
                return error.localizedDescription
            }
            return "The certificate chain could not be verified."
        case .publicKeyExtractionFailed:
            return "Unable to extract the public key data from the server certificate."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .pinningValidationFailed:
            return "Verify that the pinned certificates or public keys are correct and up to date."
        case .certificateChainInvalid:
            return "Check if the server certificate is valid and properly configured."
        case .publicKeyExtractionFailed:
            return "This may indicate an invalid or corrupted certificate from the server."
        }
    }
}

// MARK: - Equatable

extension SecurityError: Equatable {
    public static func == (lhs: SecurityError, rhs: SecurityError) -> Bool {
        switch (lhs, rhs) {
        case (.pinningValidationFailed(let lhsHost), .pinningValidationFailed(let rhsHost)):
            return lhsHost == rhsHost

        case (.certificateChainInvalid(let lhsHost, let lhsError), .certificateChainInvalid(let rhsHost, let rhsError)):
            guard lhsHost == rhsHost else { return false }
            switch (lhsError, rhsError) {
            case (nil, nil):
                return true
            case (let lhs?, let rhs?):
                let lhsNS: NSError = lhs as NSError
                let rhsNS: NSError = rhs as NSError
                return lhsNS.domain == rhsNS.domain && lhsNS.code == rhsNS.code
            default:
                return false
            }

        case (.publicKeyExtractionFailed(let lhsHost), .publicKeyExtractionFailed(let rhsHost)):
            return lhsHost == rhsHost

        default:
            return false
        }
    }
}
