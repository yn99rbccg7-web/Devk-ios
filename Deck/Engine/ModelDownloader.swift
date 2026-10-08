import Foundation
import SwiftUI

/// Downloads the GGUF model on first launch (multi-GB, Wi-Fi recommended),
/// with progress and resume support. Fully offline afterwards.
@MainActor
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle, downloading, done, failed(String)
    }

    /// Default brain: uncensored Huihui-NeoHorse 4B abliterated, Q4_K (~2.5GB).
    /// Won the tool-use head-to-head vs the 1.7B, and beat Qwen3.5-4B 9/10 to 7/10
    /// on the eval battery (2026-10-08) — Qwen3.5 confabulates facts and arithmetic.
    /// Editable in Settings at runtime.
    static let defaultModelURL =
        "https://huggingface.co/huihui-ai/Huihui-NeoHorse-1-4B-abliterated-GGUF/resolve/main/Huihui-NeoHorse-1-4B-abliterated-Q4_K.gguf"

    @Published var state: State = .idle
    @Published var progress: Double = 0
    @Published var downloadedMB: Double = 0
    @Published var totalMB: Double = 0

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private let filename: String

    init(filename: String = "models/brain-4b.gguf") {
        self.filename = filename
    }

    var modelURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    var modelExists: Bool {
        let exists = FileManager.default.fileExists(atPath: modelURL.path)
        if exists {
            totalMB = Double((try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int) ?? 0) / 1_000_000
        }
        return exists
    }

    func start(urlString: String) {
        guard let url = URL(string: urlString) else {
            state = .failed("Bad URL.")
            return
        }
        state = .downloading
        progress = 0
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        if let resumeData {
            task = session?.downloadTask(withResumeData: resumeData)
        } else {
            task = session?.downloadTask(with: url)
        }
        task?.resume()
    }

    func cancel() {
        task?.cancel { [weak self] data in
            Task { @MainActor in self?.resumeData = data }
        }
        state = .idle
    }

    // MARK: URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.downloadedMB = Double(totalBytesWritten) / 1_000_000
            self.totalMB = Double(totalBytesExpectedToWrite) / 1_000_000
            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            do {
                let dest = self.modelURL
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                // Drop legacy brains (frees space): the old 1.7B brain.gguf and the
                // Qwen3.5 brain-qwen35-4b.gguf (eval 2026-10-08: weaker than NeoHorse).
                let dir = dest.deletingLastPathComponent()
                for legacyName in ["brain.gguf", "brain-qwen35-4b.gguf"] {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(legacyName))
                }
                self.resumeData = nil
                self.state = .done
                self.progress = 1
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            if (error as NSError).code == NSURLErrorCancelled { return }
            self.resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            self.state = .failed(error.localizedDescription)
        }
    }
}
