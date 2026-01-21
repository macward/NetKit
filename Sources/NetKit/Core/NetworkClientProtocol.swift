import Foundation

/// The result of an upload operation with progress tracking.
public struct UploadResult<Response: Sendable>: Sendable {
    /// An AsyncSequence of progress updates during the upload.
    public let progress: TransferProgressStream
    /// A task that completes with the decoded response.
    public let response: Task<Response, Error>
}

/// The result of a download operation with progress tracking.
public struct DownloadResult: Sendable {
    /// An AsyncSequence of progress updates during the download.
    public let progress: TransferProgressStream
    /// A task that completes with the destination URL.
    public let response: Task<URL, Error>
}

/// A protocol for network clients, enabling dependency injection and testing.
public protocol NetworkClientProtocol: Sendable {
    /// Executes a request for the given endpoint.
    /// - Parameter endpoint: The endpoint to request.
    /// - Returns: The decoded response.
    /// - Throws: `NetworkError` if the request fails.
    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response

    // MARK: - Upload Methods

    /// Uploads a file to the specified endpoint with progress tracking.
    /// - Parameters:
    ///   - file: The URL of the file to upload.
    ///   - endpoint: The endpoint to upload to.
    /// - Returns: An `UploadResult` containing progress stream and response task.
    func upload<E: Endpoint>(file: URL, to endpoint: E) -> UploadResult<E.Response>

    /// Uploads multipart form data to the specified endpoint with progress tracking.
    /// - Parameters:
    ///   - formData: The multipart form data to upload.
    ///   - endpoint: The endpoint to upload to.
    /// - Returns: An `UploadResult` containing progress stream and response task.
    func upload<E: Endpoint>(formData: MultipartFormData, to endpoint: E) -> UploadResult<E.Response>

    // MARK: - Download Methods

    /// Downloads a file from the specified endpoint with progress tracking.
    /// - Parameters:
    ///   - endpoint: The endpoint to download from.
    ///   - destination: The URL where the file should be saved.
    /// - Returns: A `DownloadResult` containing progress stream and response task.
    func download<E: Endpoint>(from endpoint: E, to destination: URL) -> DownloadResult
}
