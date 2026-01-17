import Foundation

/// Errors that can occur during network operations.
public enum NetworkError: Error, Sendable, Equatable {
    case invalidURL
    case noConnection
    case timeout
    case unauthorized
    case forbidden
    case notFound
    case noContent
    case serverError(statusCode: Int)
    case decodingError(Error)
    case encodingError(Error)
    case unknown(Error)

    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.noConnection, .noConnection),
             (.timeout, .timeout),
             (.unauthorized, .unauthorized),
             (.forbidden, .forbidden),
             (.notFound, .notFound),
             (.noContent, .noContent):
            return true
        case let (.serverError(lhsCode), .serverError(rhsCode)):
            return lhsCode == rhsCode
        case let (.decodingError(lhsError), .decodingError(rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        case let (.encodingError(lhsError), .encodingError(rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        case let (.unknown(lhsError), .unknown(rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}
