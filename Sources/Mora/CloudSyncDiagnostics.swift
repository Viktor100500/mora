import Foundation
import FinanceCore

/// Local, bounded diagnostics. Never include request bodies, URLs, credentials or error descriptions.
@MainActor
final class CloudSyncDiagnostics {
    private let fileURL: URL
    private let session = UUID().uuidString
    private let limit = 512 * 1024

    init(directory: URL) { fileURL = directory.appendingPathComponent("cloud-sync-diagnostics.log") }

    func record(_ event: String, error: Error? = nil, taskCancelled: Bool = false) {
        var line = "\(Date().ISO8601Format()) session=\(session) event=\(event) task_cancelled=\(taskCancelled)"
        if let error {
            let value = error as NSError
            let category: String
            if error is CancellationError { category = "swift-cancellation" }
            else if value.domain == NSURLErrorDomain { category = "url-\(value.code)" }
            else if error is CloudAPIError { category = "cloud-api" }
            else { category = "other" }
            line += " error=\(category)"
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSURLErrorDomain { line += " underlying=url-\(underlying.code)" }
        }
        line += "\n"
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size >= limit || !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Diagnostics must never interrupt synchronization.
        }
    }
}
