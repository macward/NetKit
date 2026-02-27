import Testing
import Foundation
@testable import NetKit

// MARK: - TransferProgress Tests

@Suite("TransferProgress Tests")
struct TransferProgressTests {
    @Test("Initializes with correct values")
    func initialization() {
        let progress: TransferProgress = TransferProgress(
            bytesCompleted: 500,
            totalBytes: 1000,
            isComplete: false,
            estimatedTimeRemaining: 10,
            bytesPerSecond: 50
        )

        #expect(progress.bytesCompleted == 500)
        #expect(progress.totalBytes == 1000)
        #expect(progress.isComplete == false)
        #expect(progress.estimatedTimeRemaining == 10)
        #expect(progress.bytesPerSecond == 50)
    }

    @Test("Calculates fractionCompleted correctly")
    func fractionCompleted() {
        let progress: TransferProgress = TransferProgress(
            bytesCompleted: 250,
            totalBytes: 1000
        )

        #expect(progress.fractionCompleted == 0.25)
    }

    @Test("fractionCompleted is nil when totalBytes is nil")
    func fractionCompletedNilWhenTotalNil() {
        let progress: TransferProgress = TransferProgress(
            bytesCompleted: 500,
            totalBytes: nil
        )

        #expect(progress.fractionCompleted == nil)
    }

    @Test("fractionCompleted is nil when totalBytes is zero")
    func fractionCompletedNilWhenTotalZero() {
        let progress: TransferProgress = TransferProgress(
            bytesCompleted: 0,
            totalBytes: 0
        )

        #expect(progress.fractionCompleted == nil)
    }

    @Test("Zero static property creates empty progress")
    func zeroProgress() {
        let progress: TransferProgress = .zero

        #expect(progress.bytesCompleted == 0)
        #expect(progress.totalBytes == nil)
        #expect(progress.isComplete == false)
    }

    @Test("Completed static factory creates completed progress")
    func completedProgress() {
        let progress: TransferProgress = .completed(totalBytes: 1000)

        #expect(progress.bytesCompleted == 1000)
        #expect(progress.totalBytes == 1000)
        #expect(progress.isComplete == true)
        #expect(progress.fractionCompleted == 1.0)
    }

    @Test("TransferProgress is equatable")
    func equatable() {
        let progress1: TransferProgress = TransferProgress(
            bytesCompleted: 500,
            totalBytes: 1000,
            isComplete: false
        )
        let progress2: TransferProgress = TransferProgress(
            bytesCompleted: 500,
            totalBytes: 1000,
            isComplete: false
        )
        let progress3: TransferProgress = TransferProgress(
            bytesCompleted: 600,
            totalBytes: 1000,
            isComplete: false
        )

        #expect(progress1 == progress2)
        #expect(progress1 != progress3)
    }

    @Test("Description includes percentage")
    func descriptionIncludesPercentage() {
        let progress: TransferProgress = TransferProgress(
            bytesCompleted: 500,
            totalBytes: 1000
        )

        let description: String = progress.description
        #expect(description.contains("50.0%"))
    }

    @Test("Description includes ETA when available")
    func descriptionIncludesETA() {
        let progress: TransferProgress = TransferProgress(
            bytesCompleted: 500,
            totalBytes: 1000,
            estimatedTimeRemaining: 30
        )

        let description: String = progress.description
        #expect(description.contains("ETA"))
    }
}

// MARK: - TransferProgressStream Tests

@Suite("TransferProgressStream Tests")
struct TransferProgressStreamTests {
    @Test("Empty stream completes immediately")
    func emptyStream() async {
        let stream: TransferProgressStream = .empty
        var count: Int = 0

        for await _ in stream {
            count += 1
        }

        #expect(count == 0)
    }

    @Test("Completed stream yields single progress")
    func completedStream() async {
        let stream: TransferProgressStream = .completed(totalBytes: 1000)
        let results: [TransferProgress] = await stream.collect()

        #expect(results.count == 1)
        #expect(results[0].isComplete == true)
        #expect(results[0].totalBytes == 1000)
    }

    @Test("Stream from sequence yields all elements")
    func streamFromSequence() async {
        let sequence: [TransferProgress] = [
            TransferProgress(bytesCompleted: 100, totalBytes: 1000),
            TransferProgress(bytesCompleted: 500, totalBytes: 1000),
            TransferProgress(bytesCompleted: 1000, totalBytes: 1000, isComplete: true)
        ]
        let stream: TransferProgressStream = .from(sequence)
        let results: [TransferProgress] = await stream.collect()

        #expect(results.count == 3)
        #expect(results[0].bytesCompleted == 100)
        #expect(results[1].bytesCompleted == 500)
        #expect(results[2].bytesCompleted == 1000)
    }

    @Test("Last returns final progress")
    func lastProgress() async {
        let sequence: [TransferProgress] = [
            TransferProgress(bytesCompleted: 100, totalBytes: 1000),
            TransferProgress(bytesCompleted: 500, totalBytes: 1000),
            TransferProgress(bytesCompleted: 1000, totalBytes: 1000, isComplete: true)
        ]
        let stream: TransferProgressStream = .from(sequence)
        let last: TransferProgress? = await stream.last()

        #expect(last != nil)
        #expect(last?.bytesCompleted == 1000)
        #expect(last?.isComplete == true)
    }

    @Test("Last returns nil for empty stream")
    func lastNilForEmptyStream() async {
        let stream: TransferProgressStream = .empty
        let last: TransferProgress? = await stream.last()

        #expect(last == nil)
    }
}

// MARK: - MultipartFormData Tests

@Suite("MultipartFormData Tests")
struct MultipartFormDataTests {
    @Test("Generates content type with boundary")
    func contentTypeWithBoundary() {
        let formData: MultipartFormData = MultipartFormData()

        let contentType: String = formData.contentType
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    }

    @Test("Appends string value")
    func appendStringValue() {
        let formData: MultipartFormData = MultipartFormData()
        formData.append(value: "John", name: "name")

        let (data, contentType): (data: Data, contentType: String) = formData.encode()
        let string: String = String(data: data, encoding: .utf8)!

        #expect(string.contains("name=\"name\""))
        #expect(string.contains("John"))
        #expect(contentType.contains("multipart/form-data"))
    }

    @Test("Appends data with filename")
    func appendDataWithFilename() {
        let formData: MultipartFormData = MultipartFormData()
        let imageData: Data = "fake image data".data(using: .utf8)!
        formData.append(data: imageData, name: "avatar", filename: "photo.jpg")

        let (data, _): (data: Data, contentType: String) = formData.encode()
        let string: String = String(data: data, encoding: .utf8)!

        #expect(string.contains("name=\"avatar\""))
        #expect(string.contains("filename=\"photo.jpg\""))
        #expect(string.contains("Content-Type: image/jpeg"))
    }

    @Test("Appends data with custom MIME type")
    func appendDataWithCustomMimeType() {
        let formData: MultipartFormData = MultipartFormData()
        let data: Data = "custom data".data(using: .utf8)!
        formData.append(data: data, name: "file", filename: "data.bin", mimeType: "application/octet-stream")

        let (encodedData, _): (data: Data, contentType: String) = formData.encode()
        let string: String = String(data: encodedData, encoding: .utf8)!

        #expect(string.contains("Content-Type: application/octet-stream"))
    }

    @Test("Infers MIME type from extension")
    func infersMimeTypeFromExtension() {
        let formData: MultipartFormData = MultipartFormData()

        formData.append(data: Data(), name: "image", filename: "photo.png")
        formData.append(data: Data(), name: "doc", filename: "document.pdf")
        formData.append(data: Data(), name: "video", filename: "movie.mp4")

        let (data, _): (data: Data, contentType: String) = formData.encode()
        let string: String = String(data: data, encoding: .utf8)!

        #expect(string.contains("Content-Type: image/png"))
        #expect(string.contains("Content-Type: application/pdf"))
        #expect(string.contains("Content-Type: video/mp4"))
    }

    @Test("Encodes multiple parts correctly")
    func encodesMultipleParts() {
        let formData: MultipartFormData = MultipartFormData()
        formData.append(value: "John", name: "firstName")
        formData.append(value: "Doe", name: "lastName")
        formData.append(data: "file content".data(using: .utf8)!, name: "file", filename: "test.txt")

        let (data, _): (data: Data, contentType: String) = formData.encode()
        let string: String = String(data: data, encoding: .utf8)!

        #expect(string.contains("firstName"))
        #expect(string.contains("lastName"))
        #expect(string.contains("test.txt"))
    }

    @Test("Custom boundary is used")
    func customBoundary() {
        let formData: MultipartFormData = MultipartFormData(boundary: "CustomBoundary123")
        formData.append(value: "test", name: "field")

        let (data, contentType): (data: Data, contentType: String) = formData.encode()
        let string: String = String(data: data, encoding: .utf8)!

        #expect(contentType.contains("boundary=CustomBoundary123"))
        #expect(string.contains("--CustomBoundary123"))
    }

    @Test("Encodes closing boundary")
    func encodesClosingBoundary() {
        let formData: MultipartFormData = MultipartFormData(boundary: "TestBoundary")
        formData.append(value: "test", name: "field")

        let (data, _): (data: Data, contentType: String) = formData.encode()
        let string: String = String(data: data, encoding: .utf8)!

        #expect(string.contains("--TestBoundary--"))
    }
}

// MARK: - Upload/Download Result Tests

@Suite("UploadResult Tests")
struct UploadResultTests {
    @Test("UploadResult contains progress stream and response task")
    func uploadResultStructure() {
        let stream: TransferProgressStream = .empty
        let task: Task<String, Error> = Task { "response" }
        let result: UploadResult<String> = UploadResult(progress: stream, response: task)

        #expect(result.progress != nil)
        #expect(result.response != nil)
    }
}

@Suite("DownloadResult Tests")
struct DownloadResultTests {
    @Test("DownloadResult contains progress stream and response task")
    func downloadResultStructure() {
        let stream: TransferProgressStream = .empty
        let task: Task<URL, Error> = Task { URL(fileURLWithPath: "/tmp/test") }
        let result: DownloadResult = DownloadResult(progress: stream, response: task)

        #expect(result.progress != nil)
        #expect(result.response != nil)
    }
}

// MARK: - MockNetworkClient Upload/Download Tests

struct UploadEndpoint: Endpoint {
    var path: String { "/upload" }
    var method: HTTPMethod { .post }

    typealias Response = UploadResponse
}

struct UploadResponse: Codable, Equatable, Sendable {
    let fileId: String
    let size: Int
}

struct DownloadEndpoint: Endpoint {
    let fileId: String

    var path: String { "/files/\(fileId)" }
    var method: HTTPMethod { .get }

    typealias Response = EmptyResponse
}

@Suite("MockNetworkClient Upload Tests")
struct MockNetworkClientUploadTests {
    @Test("Upload returns stubbed response")
    func uploadReturnsStubResponse() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        let expectedResponse: UploadResponse = UploadResponse(fileId: "123", size: 1024)

        await client.stubUpload(UploadEndpoint.self) { _ in expectedResponse }

        let result: UploadResult<UploadResponse> = await client.upload(
            file: URL(fileURLWithPath: "/tmp/test.txt"),
            to: UploadEndpoint()
        )

        let response: UploadResponse = try await result.response.value
        #expect(response == expectedResponse)
    }

    @Test("Upload tracks call count")
    func uploadTracksCallCount() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        await client.stubUpload(UploadEndpoint.self) { _ in
            UploadResponse(fileId: "123", size: 1024)
        }

        _ = await client.upload(file: URL(fileURLWithPath: "/tmp/test.txt"), to: UploadEndpoint())
        _ = await client.upload(file: URL(fileURLWithPath: "/tmp/test2.txt"), to: UploadEndpoint())

        try await Task.sleep(nanoseconds: 100_000_000)

        let count: Int = await client.callCount(for: UploadEndpoint.self)
        #expect(count == 2)
    }

    @Test("Upload with form data returns stubbed response")
    func uploadFormDataReturnsStubResponse() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        let expectedResponse: UploadResponse = UploadResponse(fileId: "456", size: 2048)

        await client.stubUpload(UploadEndpoint.self) { _ in expectedResponse }

        let formData: MultipartFormData = MultipartFormData()
        formData.append(value: "test", name: "name")

        let result: UploadResult<UploadResponse> = await client.upload(formData: formData, to: UploadEndpoint())

        let response: UploadResponse = try await result.response.value
        #expect(response == expectedResponse)
    }

    @Test("Upload with progress sequence emits progress")
    func uploadEmitsProgress() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        let progressSequence: [TransferProgress] = [
            TransferProgress(bytesCompleted: 100, totalBytes: 1000),
            TransferProgress(bytesCompleted: 500, totalBytes: 1000),
            TransferProgress(bytesCompleted: 1000, totalBytes: 1000, isComplete: true)
        ]

        await client.stubUpload(
            UploadEndpoint.self,
            progressSequence: progressSequence
        ) { _ in
            UploadResponse(fileId: "123", size: 1000)
        }

        let result: UploadResult<UploadResponse> = await client.upload(
            file: URL(fileURLWithPath: "/tmp/test.txt"),
            to: UploadEndpoint()
        )

        var progressUpdates: [TransferProgress] = []
        for await progress in result.progress {
            progressUpdates.append(progress)
        }

        #expect(progressUpdates.count >= 3)
    }

    @Test("Upload throws stubbed error")
    func uploadThrowsStubError() async {
        let client: MockNetworkClient = MockNetworkClient()
        await client.stubError(UploadEndpoint.self, error: .timeout())

        let result: UploadResult<UploadResponse> = await client.upload(
            file: URL(fileURLWithPath: "/tmp/test.txt"),
            to: UploadEndpoint()
        )

        do {
            _ = try await result.response.value
            Issue.record("Expected error to be thrown")
        } catch let error as NetworkError {
            #expect(error.kind == .timeout)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

@Suite("MockNetworkClient Download Tests")
struct MockNetworkClientDownloadTests {
    @Test("Download returns destination URL")
    func downloadReturnsDestination() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        let destination: URL = URL(fileURLWithPath: "/tmp/downloaded.txt")

        await client.stubDownload(
            DownloadEndpoint.self,
            destinationURL: destination
        )

        let result: DownloadResult = await client.download(
            from: DownloadEndpoint(fileId: "123"),
            to: destination
        )

        let savedURL: URL = try await result.response.value
        #expect(savedURL == destination)
    }

    @Test("Download tracks call count")
    func downloadTracksCallCount() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        let destination: URL = URL(fileURLWithPath: "/tmp/downloaded.txt")

        await client.stubDownload(
            DownloadEndpoint.self,
            destinationURL: destination
        )

        _ = await client.download(from: DownloadEndpoint(fileId: "1"), to: destination)
        _ = await client.download(from: DownloadEndpoint(fileId: "2"), to: destination)

        try await Task.sleep(nanoseconds: 100_000_000)

        let count: Int = await client.callCount(for: DownloadEndpoint.self)
        #expect(count == 2)
    }

    @Test("Download with progress sequence emits progress")
    func downloadEmitsProgress() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        let destination: URL = URL(fileURLWithPath: "/tmp/downloaded.txt")
        let progressSequence: [TransferProgress] = [
            TransferProgress(bytesCompleted: 1000, totalBytes: 10000),
            TransferProgress(bytesCompleted: 5000, totalBytes: 10000),
            TransferProgress(bytesCompleted: 10000, totalBytes: 10000, isComplete: true)
        ]

        await client.stubDownload(
            DownloadEndpoint.self,
            progressSequence: progressSequence,
            destinationURL: destination
        )

        let result: DownloadResult = await client.download(
            from: DownloadEndpoint(fileId: "123"),
            to: destination
        )

        var progressUpdates: [TransferProgress] = []
        for await progress in result.progress {
            progressUpdates.append(progress)
        }

        #expect(progressUpdates.count >= 3)
    }

    @Test("Download throws stubbed error")
    func downloadThrowsStubError() async {
        let client: MockNetworkClient = MockNetworkClient()
        let destination: URL = URL(fileURLWithPath: "/tmp/downloaded.txt")

        await client.stubError(DownloadEndpoint.self, error: .notFound())

        let result: DownloadResult = await client.download(
            from: DownloadEndpoint(fileId: "123"),
            to: destination
        )

        do {
            _ = try await result.response.value
            Issue.record("Expected error to be thrown")
        } catch let error as NetworkError {
            #expect(error.kind == .notFound)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

@Suite("MockNetworkClient Concurrent Access Tests")
struct MockNetworkClientConcurrentAccessTests {
    @Test("Concurrent uploads are thread-safe")
    func concurrentUploadsAreThreadSafe() async throws {
        let client: MockNetworkClient = MockNetworkClient()

        await client.stubUpload(UploadEndpoint.self) { endpoint in
            UploadResponse(fileId: "file-123", size: 100)
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    let result: UploadResult<UploadResponse> = await client.upload(
                        file: URL(fileURLWithPath: "/tmp/test-\(index).txt"),
                        to: UploadEndpoint()
                    )
                    _ = try? await result.response.value
                }
            }
        }

        let callCount: Int = await client.callCount(for: UploadEndpoint.self)
        #expect(callCount == 50)
    }

    @Test("Concurrent downloads are thread-safe")
    func concurrentDownloadsAreThreadSafe() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        let destination: URL = URL(fileURLWithPath: "/tmp/downloaded.txt")

        await client.stubDownload(
            DownloadEndpoint.self,
            destinationURL: destination
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    let result: DownloadResult = await client.download(
                        from: DownloadEndpoint(fileId: "\(index)"),
                        to: destination
                    )
                    _ = try? await result.response.value
                }
            }
        }

        let callCount: Int = await client.callCount(for: DownloadEndpoint.self)
        #expect(callCount == 50)
    }

    @Test("Concurrent mixed operations are thread-safe")
    func concurrentMixedOperationsAreThreadSafe() async throws {
        let client: MockNetworkClient = MockNetworkClient()
        let destination: URL = URL(fileURLWithPath: "/tmp/downloaded.txt")

        await client.stubUpload(UploadEndpoint.self) { _ in
            UploadResponse(fileId: "123", size: 1024)
        }
        await client.stubDownload(
            DownloadEndpoint.self,
            destinationURL: destination
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<25 {
                group.addTask {
                    let result: UploadResult<UploadResponse> = await client.upload(
                        file: URL(fileURLWithPath: "/tmp/test-\(index).txt"),
                        to: UploadEndpoint()
                    )
                    _ = try? await result.response.value
                }
                group.addTask {
                    let result: DownloadResult = await client.download(
                        from: DownloadEndpoint(fileId: "\(index)"),
                        to: destination
                    )
                    _ = try? await result.response.value
                }
            }
        }

        let uploadCount: Int = await client.callCount(for: UploadEndpoint.self)
        let downloadCount: Int = await client.callCount(for: DownloadEndpoint.self)
        #expect(uploadCount == 25)
        #expect(downloadCount == 25)
    }
}
