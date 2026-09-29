import Foundation
import UIKit
import UserNotifications

enum ToolError: Error, LocalizedError {
    case pathEscape
    case io(String)

    var errorDescription: String? {
        switch self {
        case .pathEscape: return "Path escapes the deck folder."
        case .io(let s): return s
        }
    }
}

/// The deck's hands: sandboxed file tools, memory, tasks, web, notifications.
final class DeckTools {
    static let knownTools: Set<String> = [
        "read_file", "write_file", "append_file", "list_dir", "delete_file",
        "remember", "recall",
        "add_task", "list_tasks", "complete_task",
        "http_fetch", "get_date", "notify", "open_url",
    ]

    private let store = MemoryStore.shared

    private var deckRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("deck", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func jailed(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, relativeTo: deckRoot).standardizedFileURL
        guard url.path.hasPrefix(deckRoot.path) else { throw ToolError.pathEscape }
        return url
    }

    func run(name: String, args: [String: String]) async throws -> String {
        switch name {
        case "read_file":
            let url = try jailed(args["path"] ?? "")
            return try String(contentsOf: url, encoding: .utf8)

        case "write_file":
            let url = try jailed(args["path"] ?? "")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try (args["content"] ?? "").write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(args["path"] ?? "") (\(args["content"]?.count ?? 0) chars)."

        case "append_file":
            let url = try jailed(args["path"] ?? "")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try (existing + (args["content"] ?? "")).write(to: url, atomically: true, encoding: .utf8)
            return "Appended to \(args["path"] ?? "")."

        case "list_dir":
            let url = try jailed(args["path"] ?? "")
            let items = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return items.isEmpty ? "(empty)" : items.sorted().joined(separator: "\n")

        case "delete_file":
            let url = try jailed(args["path"] ?? "")
            try FileManager.default.removeItem(at: url)
            return "Deleted \(args["path"] ?? "")."

        case "remember":
            try store.remember(key: args["key"] ?? "", value: args["value"] ?? "")
            return "Remembered."

        case "recall":
            let hits = try store.recall(query: args["query"] ?? "")
            return hits.isEmpty ? "(no memories match)" : hits.joined(separator: "\n---\n")

        case "add_task":
            let id = try store.addTask(title: args["title"] ?? "")
            return "Task #\(id) added."

        case "list_tasks":
            let tasks = try store.listTasks()
            return tasks.isEmpty ? "(no open tasks)" : tasks.joined(separator: "\n")

        case "complete_task":
            try store.completeTask(id: Int64(Int(args["id"] ?? "") ?? -1))
            return "Task completed."

        case "http_fetch":
            guard let urlString = args["url"], let url = URL(string: urlString) else {
                throw ToolError.io("Bad URL.")
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            var text = String(data: data, encoding: .utf8) ?? "(binary content)"
            // Strip tags crudely for readability.
            text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return String(text.prefix(6000))

        case "get_date":
            let f = DateFormatter()
            f.dateStyle = .full
            f.timeStyle = .short
            return f.string(from: Date())

        case "notify":
            let center = UNUserNotificationCenter.current()
            let granted = await withCheckedContinuation { c in
                center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in c.resume(returning: ok) }
            }
            guard granted else { return "Notification permission denied." }
            let content = UNMutableNotificationContent()
            content.title = args["title"] ?? "Deck"
            content.body = args["body"] ?? ""
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
            try await center.add(req)
            return "Notification sent."

        case "open_url":
            guard let s = args["url"], let url = URL(string: s) else {
                throw ToolError.io("Bad URL.")
            }
            await MainActor.run { UIApplication.shared.open(url) }
            return "Opened."

        default:
            throw ToolError.io("Unknown tool: \(name)")
        }
    }
}
