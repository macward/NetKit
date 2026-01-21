import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A builder for constructing multipart/form-data requests.
///
/// Use this class to build multipart form data for file uploads:
/// ```swift
/// let formData = MultipartFormData()
/// formData.append(data: imageData, name: "avatar", filename: "photo.jpg")
/// formData.append(value: "John", name: "name")
///
/// let (progress, responseTask) = client.upload(formData: formData, to: endpoint)
/// ```
public final class MultipartFormData: @unchecked Sendable {
    private var parts: [Part] = []
    private let boundary: String

    /// The content type header value for this multipart form data.
    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Creates a new multipart form data builder.
    /// - Parameter boundary: Custom boundary string. If nil, a random boundary is generated.
    public init(boundary: String? = nil) {
        self.boundary = boundary ?? Self.generateBoundary()
    }

    // MARK: - Append Methods

    /// Appends raw data as a form field.
    /// - Parameters:
    ///   - data: The data to append.
    ///   - name: The form field name.
    ///   - filename: Optional filename for file uploads.
    ///   - mimeType: Optional MIME type. If nil, will be inferred from filename.
    public func append(
        data: Data,
        name: String,
        filename: String? = nil,
        mimeType: String? = nil
    ) {
        let resolvedMimeType: String?
        if let mimeType {
            resolvedMimeType = mimeType
        } else if let filename {
            resolvedMimeType = Self.mimeType(for: filename)
        } else {
            resolvedMimeType = nil
        }

        let part: Part = Part(
            name: name,
            filename: filename,
            mimeType: resolvedMimeType,
            data: data
        )
        parts.append(part)
    }

    /// Appends a string value as a form field.
    ///
    /// - Note: Uses UTF-8 encoding. All valid Swift strings can be encoded as UTF-8,
    ///   so this method will always succeed for normal string values.
    ///
    /// - Parameters:
    ///   - value: The string value to append.
    ///   - name: The form field name.
    public func append(value: String, name: String) {
        // UTF-8 encoding of Swift strings should never fail for valid strings
        let data: Data = Data(value.utf8)
        let part: Part = Part(
            name: name,
            filename: nil,
            mimeType: nil,
            data: data
        )
        parts.append(part)
    }

    /// Appends a file from a URL as a form field.
    /// - Parameters:
    ///   - fileURL: The URL of the file to append.
    ///   - name: The form field name.
    ///   - filename: Optional filename. If nil, uses the file's name from the URL.
    ///   - mimeType: Optional MIME type. If nil, will be inferred from filename.
    /// - Throws: An error if the file cannot be read.
    public func append(
        fileURL: URL,
        name: String,
        filename: String? = nil,
        mimeType: String? = nil
    ) throws {
        let data: Data = try Data(contentsOf: fileURL)
        let resolvedFilename: String = filename ?? fileURL.lastPathComponent

        append(
            data: data,
            name: name,
            filename: resolvedFilename,
            mimeType: mimeType
        )
    }

    // MARK: - Encoding

    /// Encodes the multipart form data into a Data object.
    /// - Returns: A tuple containing the encoded data and content type header value.
    public func encode() -> (data: Data, contentType: String) {
        var body: Data = Data()
        let boundaryPrefix: String = "--\(boundary)\r\n"

        for part in parts {
            body.append(contentsOf: boundaryPrefix.utf8)
            body.append(contentsOf: part.headers.utf8)
            body.append(part.data)
            body.append(contentsOf: "\r\n".utf8)
        }

        body.append(contentsOf: "--\(boundary)--\r\n".utf8)

        return (data: body, contentType: contentType)
    }

    // MARK: - Private

    private struct Part {
        let name: String
        let filename: String?
        let mimeType: String?
        let data: Data

        var headers: String {
            var headers: String = "Content-Disposition: form-data; name=\"\(name)\""

            if let filename {
                headers += "; filename=\"\(filename)\""
            }
            headers += "\r\n"

            if let mimeType {
                headers += "Content-Type: \(mimeType)\r\n"
            }

            headers += "\r\n"
            return headers
        }
    }

    private static func generateBoundary() -> String {
        "NetKit.Boundary.\(UUID().uuidString)"
    }

    /// Infers MIME type from filename extension.
    /// - Parameter filename: The filename to infer type from.
    /// - Returns: The MIME type, or "application/octet-stream" if unknown.
    private static func mimeType(for filename: String) -> String {
        let pathExtension: String = (filename as NSString).pathExtension.lowercased()

        #if canImport(UniformTypeIdentifiers)
        if let utType = UTType(filenameExtension: pathExtension),
           let mimeType = utType.preferredMIMEType {
            return mimeType
        }
        #endif

        return extensionToMimeType[pathExtension] ?? "application/octet-stream"
    }

    /// Fallback MIME type mapping for common file types.
    private static let extensionToMimeType: [String: String] = [
        // Images
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "webp": "image/webp",
        "heic": "image/heic",
        "heif": "image/heif",
        "svg": "image/svg+xml",
        "ico": "image/x-icon",
        "bmp": "image/bmp",
        "tiff": "image/tiff",
        "tif": "image/tiff",

        // Documents
        "pdf": "application/pdf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",

        // Text
        "txt": "text/plain",
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "csv": "text/csv",
        "xml": "text/xml",
        "json": "application/json",
        "js": "application/javascript",

        // Audio
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "ogg": "audio/ogg",
        "flac": "audio/flac",

        // Video
        "mp4": "video/mp4",
        "m4v": "video/mp4",
        "mov": "video/quicktime",
        "avi": "video/x-msvideo",
        "wmv": "video/x-ms-wmv",
        "webm": "video/webm",
        "mkv": "video/x-matroska",

        // Archives
        "zip": "application/zip",
        "tar": "application/x-tar",
        "gz": "application/gzip",
        "rar": "application/vnd.rar",
        "7z": "application/x-7z-compressed"
    ]
}

// MARK: - Sendable Wrapper

/// A sendable wrapper for MultipartFormData that captures encoded data.
internal struct EncodedMultipartFormData: Sendable {
    let data: Data
    let contentType: String

    init(from formData: MultipartFormData) {
        let encoded = formData.encode()
        self.data = encoded.data
        self.contentType = encoded.contentType
    }
}
