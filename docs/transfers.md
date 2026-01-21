# Upload & Download

NetKit provides upload and download functionality with real-time progress tracking using AsyncStream.

## File Upload

```swift
struct UploadEndpoint: Endpoint {
    var path: String { "/files/upload" }
    var method: HTTPMethod { .post }

    typealias Response = UploadResponse
}

struct UploadResponse: Codable, Sendable {
    let fileId: String
    let size: Int
}

// Upload a file with progress tracking
let fileURL = URL(fileURLWithPath: "/path/to/file.jpg")
let (progress, responseTask) = client.upload(file: fileURL, to: UploadEndpoint())

// Track progress
for await update in progress {
    print("Progress: \(Int((update.fractionCompleted ?? 0) * 100))%")

    if let speed = update.bytesPerSecond {
        print("Speed: \(Int(speed / 1024)) KB/s")
    }

    if let eta = update.estimatedTimeRemaining {
        print("ETA: \(Int(eta)) seconds")
    }
}

// Get the response
let response = try await responseTask.value
print("Uploaded file ID: \(response.fileId)")
```

## Multipart Form Data Upload

```swift
let formData = MultipartFormData()

// Add file data
formData.append(data: imageData, name: "avatar", filename: "photo.jpg")

// Add string fields
formData.append(value: "John Doe", name: "name")
formData.append(value: "john@example.com", name: "email")

// Add file from URL
try formData.append(fileURL: documentURL, name: "document", filename: "resume.pdf")

// Upload with progress
let (progress, responseTask) = client.upload(formData: formData, to: ProfileEndpoint())

for await update in progress {
    print("\(update)") // "50.0% 512 KB of 1 MB (256 KB/s) ETA: 2s"
}

let response = try await responseTask.value
```

## File Download

```swift
struct FileEndpoint: Endpoint {
    let fileId: String

    var path: String { "/files/\(fileId)" }
    var method: HTTPMethod { .get }

    typealias Response = EmptyResponse
}

// Download to a specific location
let destination = FileManager.default.temporaryDirectory
    .appendingPathComponent("downloaded.zip")

let (progress, responseTask) = client.download(from: FileEndpoint(fileId: "123"), to: destination)

// Track download progress
for await update in progress {
    let percent = Int((update.fractionCompleted ?? 0) * 100)
    let downloaded = ByteCountFormatter.string(fromByteCount: update.bytesCompleted, countStyle: .file)

    if let total = update.totalBytes {
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        print("\(percent)% - \(downloaded) of \(totalStr)")
    }
}

// Get the saved file URL
let savedURL = try await responseTask.value
print("File saved to: \(savedURL.path)")
```

## TransferProgress Properties

```swift
public struct TransferProgress {
    /// Bytes transferred so far
    let bytesCompleted: Int64

    /// Total expected bytes (nil if unknown)
    let totalBytes: Int64?

    /// Progress fraction from 0.0 to 1.0 (nil if total unknown)
    var fractionCompleted: Double?

    /// Whether the transfer has completed
    let isComplete: Bool

    /// Estimated seconds remaining (nil if cannot be calculated)
    let estimatedTimeRemaining: TimeInterval?

    /// Current transfer speed in bytes/second
    let bytesPerSecond: Double?
}
```

## Concurrent Progress Tracking

You can track progress while doing other work:

```swift
let (progress, responseTask) = client.upload(file: largeFileURL, to: UploadEndpoint())

// Start progress tracking in background
Task {
    for await update in progress {
        await MainActor.run {
            progressView.progress = update.fractionCompleted ?? 0
        }
    }
}

// Do other work while upload happens
await prepareNextUpload()

// Wait for upload to complete
let response = try await responseTask.value
```

## MIME Type Detection

`MultipartFormData` automatically detects MIME types from file extensions:

| Extension | MIME Type |
|-----------|-----------|
| jpg, jpeg | image/jpeg |
| png | image/png |
| gif | image/gif |
| pdf | application/pdf |
| json | application/json |
| mp4 | video/mp4 |
| mp3 | audio/mpeg |
| zip | application/zip |
| ... | (50+ types supported) |

You can also specify MIME types explicitly:

```swift
formData.append(data: data, name: "file", filename: "data.bin", mimeType: "application/octet-stream")
```
