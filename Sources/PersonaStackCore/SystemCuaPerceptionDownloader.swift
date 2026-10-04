import Foundation

public struct SystemCuaPerceptionDownloader: CuaPerceptionDownloading {
    public init() {}

    public func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let delegate = PerceptionDownloadLimit(maximumBytes: maximumBytes)
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes else { throw CuaPerceptionError.invalidArtifact }
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

private final class PerceptionDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
