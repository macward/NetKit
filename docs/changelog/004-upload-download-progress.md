# Task 004: Upload/Download Progress Tracking

**Completed**: 2026-01-21
**Branch**: main
**Status**: Done

## Summary

Implemented upload and download functionality with real-time progress tracking using task-specific delegates and AsyncStream. Includes support for file uploads, multipart form data, and file downloads with progress updates including transfer speed and ETA calculations.

## Changes

### Added
- `Sources/NetKit/Progress/TransferProgress.swift` - Progress model with:
  - `bytesCompleted`, `totalBytes`, `fractionCompleted` (0.0-1.0)
  - `isComplete`, `estimatedTimeRemaining`, `bytesPerSecond`
  - Static factories: `.zero`, `.completed(totalBytes:)`
  - Human-readable description with formatted bytes and time

- `Sources/NetKit/Progress/TransferProgressStream.swift` - AsyncSequence wrapper:
  - Wraps `AsyncStream<TransferProgress>` for ergonomic consumption
  - `collect()` for testing, `last()` for final progress
  - Static factories: `.empty`, `.completed(totalBytes:)`, `.from(_:)`

- `Sources/NetKit/Progress/ProgressDelegate.swift` - URLSession delegates:
  - `UploadProgressDelegate`: Tracks `didSendBodyData` callbacks
  - `DownloadProgressDelegate`: Tracks `didWriteData` callbacks, moves file to destination
  - Thread-safe using `OSAllocatedUnfairLock`
  - `TransferMetrics` for speed/ETA calculations with rolling average

- `Sources/NetKit/Progress/MultipartFormData.swift` - Multipart builder:
  - `append(data:name:filename:mimeType:)` for binary data
  - `append(value:name:)` for string fields
  - `append(fileURL:name:filename:mimeType:)` for files
  - Automatic MIME type detection from file extensions
  - Support for 50+ common file types

- `Tests/NetKitTests/ProgressTests.swift` - Comprehensive tests:
  - TransferProgress calculations and edge cases
  - TransferProgressStream iteration and utilities
  - MultipartFormData encoding and MIME detection
  - MockNetworkClient upload/download stubbing

### Modified
- `Sources/NetKit/Core/NetworkClientProtocol.swift`:
  - Added `UploadResult<Response>` struct (progress + response task)
  - Added `DownloadResult` struct (progress + URL task)
  - Added `upload(file:to:)`, `upload(formData:to:)`, `download(from:to:)` signatures

- `Sources/NetKit/Core/NetworkClient.swift`:
  - Implemented upload methods with task-specific delegates
  - Implemented download method with file destination handling
  - Retry support: progress resets on each attempt
  - Interceptors applied to requests before upload/download

- `Sources/NetKit/Mock/MockNetworkClient.swift`:
  - Added `stubUpload(_:progressSequence:response:)` for upload stubbing
  - Added `stubDownload(_:progressSequence:destinationURL:)` for download stubbing
  - Progress sequences emitted with small delays for realistic testing

## Files Changed
- `Sources/NetKit/Progress/TransferProgress.swift` (created)
- `Sources/NetKit/Progress/TransferProgressStream.swift` (created)
- `Sources/NetKit/Progress/ProgressDelegate.swift` (created)
- `Sources/NetKit/Progress/MultipartFormData.swift` (created)
- `Sources/NetKit/Core/NetworkClientProtocol.swift` (modified)
- `Sources/NetKit/Core/NetworkClient.swift` (modified)
- `Sources/NetKit/Mock/MockNetworkClient.swift` (modified)
- `Tests/NetKitTests/ProgressTests.swift` (created)

## API Usage

### File Upload
```swift
let (progress, responseTask) = client.upload(file: imageURL, to: UploadEndpoint())

for await update in progress {
    print("Progress: \(update.fractionCompleted ?? 0)")
    if let speed = update.bytesPerSecond {
        print("Speed: \(Int(speed / 1024)) KB/s")
    }
}

let response = try await responseTask.value
```

### Multipart Form Data Upload
```swift
let formData = MultipartFormData()
formData.append(data: imageData, name: "avatar", filename: "photo.jpg")
formData.append(value: "John Doe", name: "name")
formData.append(value: "john@example.com", name: "email")

let (progress, responseTask) = client.upload(formData: formData, to: ProfileEndpoint())

for await update in progress {
    print("\(update)") // "50.0% 512 KB of 1 MB (256 KB/s) ETA: 2s"
}

let response = try await responseTask.value
```

### File Download
```swift
let destination = FileManager.default.temporaryDirectory
    .appendingPathComponent("downloaded.zip")

let (progress, responseTask) = client.download(from: FileEndpoint(id: "123"), to: destination)

for await update in progress {
    if let eta = update.estimatedTimeRemaining {
        print("ETA: \(Int(eta)) seconds")
    }
}

let savedURL = try await responseTask.value
print("File saved to: \(savedURL.path)")
```

### Testing with MockNetworkClient
```swift
let client = MockNetworkClient()

// Stub upload with progress sequence
await client.stubUpload(
    UploadEndpoint.self,
    progressSequence: [
        TransferProgress(bytesCompleted: 500, totalBytes: 1000),
        TransferProgress(bytesCompleted: 1000, totalBytes: 1000, isComplete: true)
    ]
) { _ in
    UploadResponse(fileId: "123", size: 1000)
}

// Stub download
await client.stubDownload(
    DownloadEndpoint.self,
    destinationURL: URL(fileURLWithPath: "/tmp/test.zip")
)
```

## Architecture

### Thread-Safety
- `OSAllocatedUnfairLock` wraps mutable state in delegates
- Delegates marked as `@unchecked Sendable` with internal locking
- `AsyncStream.Continuation` yields progress from delegate callbacks

### Retry Behavior
- Progress resets to 0% on each retry attempt
- Consumer sees: `0%→50%→Error` ... `0%→100%→Complete`
- Uses existing `RetryPolicy` for retry decisions

### Interceptor Integration
- Request interceptors applied before upload/download starts
- Response interceptors applied to upload responses
- Downloads write directly to disk (no response interceptors)

## Supported MIME Types

Automatic detection for common extensions:
- **Images**: jpg, jpeg, png, gif, webp, heic, svg, ico, bmp, tiff
- **Documents**: pdf, doc, docx, xls, xlsx, ppt, pptx
- **Text**: txt, html, css, csv, xml, json, js
- **Audio**: mp3, wav, m4a, aac, ogg, flac
- **Video**: mp4, m4v, mov, avi, wmv, webm, mkv
- **Archives**: zip, tar, gz, rar, 7z

Falls back to `application/octet-stream` for unknown types.

## Notes

- Minimum deployment: iOS 18.0+ / macOS 15.0+ (uses `OSAllocatedUnfairLock`)
- No external dependencies
- Downloads automatically create parent directories if needed
- Downloads overwrite existing files at destination
- Speed calculation uses rolling average of last 5 samples for stability
- **Downloads do not support automatic retry** - if a download fails, initiate a new request

---

## Code Review Fixes (2026-01-21)

Following a comprehensive code review, the following issues were addressed:

### Critical Fixes

1. **AsyncStream Continuation Pattern** (`NetworkClient.swift`)
   - **Issue**: Used implicitly unwrapped optional `var continuation!` which is fragile
   - **Fix**: Replaced with `AsyncStream.makeStream()` for safe, synchronous initialization
   - **Lines affected**: upload methods (330-333, 358-361, 384-387)

2. **URLSession Memory Leak** (`ProgressDelegate.swift`, `NetworkClient.swift`)
   - **Issue**: `DownloadProgressDelegate` never invalidated its URLSession
   - **Fix**: Added `sessionBox` with `OSAllocatedUnfairLock` to store session reference
   - Added `setSession()` and `invalidateSession()` methods
   - Session is now properly invalidated on completion or error

### Important Fixes

3. **Force Cast Removal** (`NetworkClient.swift:291-293`)
   - **Issue**: `EmptyResponse() as! E.Response` could crash
   - **Fix**: Changed to safe optional cast with `if let` pattern

4. **Silent Failure in MultipartFormData** (`MultipartFormData.swift:67-76`)
   - **Issue**: `append(value:name:)` silently failed if UTF-8 encoding failed
   - **Fix**: Changed to `Data(value.utf8)` which never fails for valid Swift strings

5. **File Validation Before Upload** (`NetworkClient.swift:406-418`)
   - **Issue**: No validation that file exists before upload attempt
   - **Fix**: Added early `FileManager.fileExists()` check with proper error

6. **Public `collect()` Method** (`TransferProgressStream.swift:88`)
   - **Issue**: `collect()` was `internal` but documented as "useful for testing"
   - **Fix**: Made `public` so consumers can use it in their tests

7. **Download Retry Documentation** (`NetworkClient.swift:378-382`)
   - **Issue**: Downloads don't support retry but this wasn't documented
   - **Fix**: Added documentation note explaining retry limitation

### Files Modified in Code Review
- `Sources/NetKit/Core/NetworkClient.swift`
- `Sources/NetKit/Progress/ProgressDelegate.swift`
- `Sources/NetKit/Progress/MultipartFormData.swift`
- `Sources/NetKit/Progress/TransferProgressStream.swift`
