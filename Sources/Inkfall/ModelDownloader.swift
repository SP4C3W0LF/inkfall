import CryptoKit
import Foundation

struct ModelDownloadResult: Sendable {
    let filePath: String
}

enum ModelDownloadError: LocalizedError {
    case invalidURL
    case insecureURL
    case unsafeFilename
    case checksumMismatch
    case badResponse(String)
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a direct https model URL"
        case .insecureURL:
            return "Model URLs must use https (http is not allowed)."
        case .unsafeFilename:
            return "The server returned an unsafe file name."
        case .checksumMismatch:
            return "The downloaded model failed its integrity check."
        case .badResponse(let message):
            return message
        case .moveFailed(let message):
            return message
        }
    }
}

/// A cancelable model download with real byte-level progress, replacing the old
/// `curl --progress-bar` call (which exposed no parseable progress). Progress and
/// completion callbacks are invoked on a background delegate queue; consumers hop
/// to the main actor themselves.
final class ModelDownloadJob: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let directory: URL
    private let onProgress: @Sendable (_ fraction: Double, _ received: Int64, _ total: Int64) -> Void
    private let onFinished: @Sendable (Result<ModelDownloadResult, Error>) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var expectedSHA256: String?
    private let lock = NSLock()
    private var didFinish = false

    init(
        directory: String,
        onProgress: @escaping @Sendable (_ fraction: Double, _ received: Int64, _ total: Int64) -> Void,
        onFinished: @escaping @Sendable (Result<ModelDownloadResult, Error>) -> Void
    ) {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        self.onProgress = onProgress
        self.onFinished = onFinished
    }

    func start(urlString: String, expectedSHA256: String? = nil) {
        self.expectedSHA256 = expectedSHA256
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            finish(.failure(ModelDownloadError.invalidURL))
            return
        }
        // https only: cleartext http lets a network attacker swap the model bytes.
        guard scheme == "https" else {
            finish(.failure(ModelDownloadError.insecureURL))
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(_ result: Result<ModelDownloadResult, Error>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()

        onFinished(result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // Reject non-2xx responses so a 404/500 error page isn't saved as a model.
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                finish(.failure(ModelDownloadError.badResponse("Server returned HTTP \(http.statusCode).")))
                return
            }
            // A real model is many MB; a tiny payload is an error page, not a model.
            let attrs = try? FileManager.default.attributesOfItem(atPath: location.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            guard size >= 1024 else {
                finish(.failure(ModelDownloadError.badResponse("The download was too small to be a model.")))
                return
            }
            // When we know the expected digest (the recommended model), verify the
            // exact bytes — closing the gap where a tampered but 200-serving mirror
            // could hand us a malicious model.
            if let expected = expectedSHA256 {
                guard let actual = Self.sha256Hex(ofFileAt: location),
                      actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    finish(.failure(ModelDownloadError.checksumMismatch))
                    return
                }
            }
            // Never trust the server-supplied name: collapse to a single path component
            // and reject traversal, so a malicious Content-Disposition header can't
            // write outside the models folder (this app is unsandboxed).
            let rawName = downloadTask.response?.suggestedFilename
                ?? downloadTask.originalRequest?.url?.lastPathComponent
                ?? "model-\(UUID().uuidString)"
            let name = (rawName as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else {
                finish(.failure(ModelDownloadError.unsafeFilename))
                return
            }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(name)
            // Defense in depth: the resolved path must stay inside the models folder.
            let dirPath = directory.standardizedFileURL.path
            guard destination.standardizedFileURL.path.hasPrefix(dirPath + "/") else {
                finish(.failure(ModelDownloadError.unsafeFilename))
                return
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(ModelDownloadResult(filePath: destination.path)))
        } catch {
            finish(.failure(ModelDownloadError.moveFailed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
    }

    /// Streaming SHA-256 of a file, chunked so a ~140 MB model isn't read into
    /// memory all at once.
    private static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
