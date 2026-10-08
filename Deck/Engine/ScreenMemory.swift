import Foundation
import Photos
import UIKit

/// Rolling, self-pruning store of screen captures.
///
/// Policy (runs automatically, no user action):
/// - Keep at most 8 captures and 40 MB total. Captures are downscaled
///   JPEGs in Caches — never written back to the Photo Library.
/// - After every agent turn, captures NOT referenced in recent chat are
///   deleted oldest-first down to the caps. A capture the conversation
///   mentions by id is treated as important context and kept.
///
/// NOTE: the on-device 1.7B model is text-only — it cannot see pixels yet.
/// Captures are stored cheaply and surfaced as context now; a vision-capable
/// brain will be able to look at them. Nothing here pretends otherwise.
final class ScreenMemory: @unchecked Sendable {
    static let shared = ScreenMemory()

    struct Entry: Codable {
        let id: String
        let taken: Date
    }

    private let dir: URL
    private let manifestURL: URL
    private let maxCount = 8
    private let maxBytes = 40 * 1024 * 1024
    private let lock = NSLock()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("screen-captures", isDirectory: true)
        manifestURL = dir.appendingPathComponent("manifest.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func readManifest() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return list
    }

    private func writeManifest(_ list: [Entry]) {
        lock.lock(); defer { lock.unlock() }
        try? JSONEncoder().encode(list).write(to: manifestURL)
    }

    func ingest(asset: PHAsset) {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isSynchronous = true
        var saved: URL?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1024, height: 1024),
            contentMode: .aspectFit,
            options: opts
        ) { [dir] image, _ in
            guard let image, let data = image.jpegData(compressionQuality: 0.7) else { return }
            let id = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = dir.appendingPathComponent("screen-\(id).jpg")
            guard (try? data.write(to: url)) != nil else { return }
            saved = url
        }
        guard let url = saved else { return }
        var list = readManifest()
        list.append(Entry(id: url.deletingPathExtension().lastPathComponent, taken: Date()))
        writeManifest(list)
        prune(protecting: [])
    }

    /// One context block for the agent turn. Empty when there is nothing stored.
    func contextBlock() -> String {
        let list = readManifest()
        guard !list.isEmpty else { return "" }
        let ids = list.map(\.id).joined(separator: ", ")
        return "<|im_start|>user\nSCREEN CONTEXT: \(list.count) recent screen capture(s) stored: \(ids). They auto-delete unless referenced in chat. Mention an id to keep it.\n<|im_end|>\n"
    }

    /// Called after every agent turn. Anything the conversation didn't
    /// reference is eligible for deletion, oldest first.
    func pruneAfterTurn(recentText: String) {
        let protecting = readManifest().map(\.id).filter { recentText.contains($0) }
        prune(protecting: protecting)
    }

    private func prune(protecting: [String]) {
        var list = readManifest().sorted { $0.taken < $1.taken }
        while list.count > maxCount,
              let i = list.firstIndex(where: { !protecting.contains($0.id) }) {
            remove(list.remove(at: i))
        }
        var bytes = list.reduce(0) { $0 + fileBytes($1) }
        while bytes > maxBytes,
              let i = list.firstIndex(where: { !protecting.contains($0.id) }) {
            let e = list.remove(at: i)
            bytes -= fileBytes(e)
            remove(e)
        }
        writeManifest(list)
    }

    private func fileURL(_ e: Entry) -> URL { dir.appendingPathComponent(e.id + ".jpg") }

    private func fileBytes(_ e: Entry) -> Int {
        (try? fileURL(e).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func remove(_ e: Entry) {
        try? FileManager.default.removeItem(at: fileURL(e))
    }

    func latestURL() -> URL? {
        readManifest().max(by: { $0.taken < $1.taken }).map(fileURL)
    }
}
