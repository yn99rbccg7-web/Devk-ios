import Foundation
import Network
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
final class DeckTools: Sendable {
    static let knownTools: Set<String> = [
        "read_file", "write_file", "append_file", "list_dir", "delete_file",
        "remember", "recall",
        "add_task", "list_tasks", "complete_task",
        "http_fetch", "get_date", "notify", "open_url",
        "tcp_connect", "dns_lookup", "port_scan",
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

        case "tcp_connect":
            return await tcpConnect(host: args["host"] ?? "",
                                    port: args["port"] ?? "",
                                    timeout: Double(args["timeout"] ?? "") ?? 5)

        case "dns_lookup":
            return await dnsLookup(host: args["host"] ?? "")

        case "port_scan":
            return await portScan(host: args["host"] ?? "",
                                  ports: args["ports"] ?? "21,22,23,25,53,80,110,143,443,445,993,995,3306,3389,5900,8080,8443",
                                  timeout: Double(args["timeout"] ?? "") ?? 1.5)

        default:
            throw ToolError.io("Unknown tool: \(name)")
        }
    }

    // MARK: - Network recon (red-team)

    /// Single-resume guard for NWConnection callbacks (Swift 6-clean).
    private final class FinishBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        let cont: CheckedContinuation<String, Never>
        let conn: NWConnection
        init(_ cont: CheckedContinuation<String, Never>, _ conn: NWConnection) {
            self.cont = cont
            self.conn = conn
        }
        func finish(_ s: String) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            conn.cancel()
            cont.resume(returning: s)
        }
    }

    /// Raw TCP connect test. Real open/closed/timeout signal; raw sockets are blocked by the iOS sandbox.
    private func tcpConnect(host: String, port: String, timeout: Double) async -> String {
        guard let p = UInt16(port), !host.isEmpty else { return "Bad host/port." }
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: p)!,
                                using: .tcp)
        return await withCheckedContinuation { cont in
            let box = FinishBox(cont, conn)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.finish("OPEN \(host):\(p)")
                case .failed(let e): box.finish("CLOSED \(host):\(p) (\(e))")
                case .cancelled: box.finish("CANCELLED \(host):\(p)")
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.finish("TIMEOUT \(host):\(p) after \(timeout)s")
            }
        }
    }

    /// DNS A/AAAA resolution via getaddrinfo.
    private func dnsLookup(host: String) async -> String {
        guard !host.isEmpty else { return "Bad host." }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                let err = getaddrinfo(host, nil, &hints, &res)
                defer { if let r = res { freeaddrinfo(r) } }
                guard err == 0, res != nil else {
                    cont.resume(returning: "DNS failed: \(String(cString: gai_strerror(err)))")
                    return
                }
                var out = Set<String>()
                var p = res
                while let cur = p {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen,
                                   &buf, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 {
                        out.insert(String(cString: buf))
                    }
                    p = cur.pointee.ai_next
                }
                cont.resume(returning: out.isEmpty ? "(no addresses)" : out.sorted().joined(separator: "\n"))
            }
        }
    }

    /// Connect-based port scan (SYN/raw scan is blocked by the iOS sandbox).
    private func portScan(host: String, ports: String, timeout: Double) async -> String {
        let list = ports.split(separator: ",")
            .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        guard !host.isEmpty, !list.isEmpty else { return "Bad host/ports." }
        let targets = Array(list.prefix(100))
        let open = await withTaskGroup(of: (UInt16, Bool).self, returning: [UInt16].self) { group in
            for p in targets {
                group.addTask { (p, await self.tcpConnect(host: host, port: String(p), timeout: timeout).hasPrefix("OPEN")) }
            }
            var found: [UInt16] = []
            for await (p, isOpen) in group where isOpen { found.append(p) }
            return found
        }
        let s = open.sorted()
        return s.isEmpty ? "No open ports on \(host)."
            : "OPEN on \(host): \(s.map(String.init).joined(separator: ", "))"
    }
}
