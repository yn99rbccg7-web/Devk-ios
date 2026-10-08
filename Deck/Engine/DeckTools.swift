import Citadel
import Crypto
import Foundation
import JavaScriptCore
import Network
import Photos
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
        "ssh_exec", "js_run", "sys_scan", "jailbreak_status", "jailbreak_path", "net_status", "lan_scan", "bin_info", "social_search", "web_search", "mcp", "see_image", "list_skills", "use_skill", "book_search",
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

        case "ssh_exec":
            return await sshExec(host: args["host"] ?? "",
                                 port: Int(args["port"] ?? "") ?? 22,
                                 username: args["username"] ?? "",
                                 password: args["password"],
                                 command: args["command"] ?? "",
                                 timeout: Double(args["timeout"] ?? "") ?? 30)

        case "js_run":
            return jsRun(code: args["code"] ?? "")

        case "sys_scan":
            return await sysScan()

        case "jailbreak_path":
            return jailbreakPath()

        case "net_status":
            return await netStatus()

        case "lan_scan":
            return await lanScan()

        case "bin_info":
            return binInfo(path: args["path"] ?? "")

        case "social_search":
            return await socialSearch(platform: args["platform"] ?? "", query: args["query"] ?? "")

        case "web_search":
            return await webSearch(query: args["query"] ?? "")

        case "mcp":
            return await mcpCall(server: args["server"] ?? "",
                                 op: args["op"] ?? "list",
                                 tool: args["tool"] ?? "",
                                 arguments: args["arguments"] ?? "")

        case "see_image":
            return await seeImage(path: args["path"] ?? "", prompt: args["prompt"] ?? "")

        case "list_skills":
            return listSkills()

        case "use_skill":
            return useSkill(name: args["name"] ?? "")

        case "book_search":
            return bookSearch(query: args["query"] ?? "")

        case "jailbreak_status":
            return jailbreakStatus()

        case "port_scan":
            return await portScan(host: args["host"] ?? "",
                                  ports: args["ports"] ?? "21,22,23,25,53,80,110,143,443,445,993,995,3306,3389,5900,8080,8443",
                                  timeout: Double(args["timeout"] ?? "") ?? 1.5)

        default:
            throw ToolError.io("Unknown tool: \(name)")
        }
    }

    /// Persistent JavaScript shell (JavaScriptCore is built into iOS; state survives between calls).
    private final class JSBox: @unchecked Sendable {
        let lock = NSLock()
        let context: JSContext
        init() { context = JSContext()! }
    }
    private let jsBox = JSBox()

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

    // MARK: - SSH (Citadel, pure-Swift SSH)

    /// Run a command on a remote server via password auth (Citadel, pure-Swift SSH).
    /// Host key is accepted on first connection (TOFU pinning is future work).
    /// Key-file auth follows once the parser API is pinned against the resolved Citadel.
    /// Credentials should live in the deck's memory store, not pasted into chat.
    private func sshExec(host: String, port: Int, username: String, password: String?,
                         command: String, timeout: Double) async -> String {
        guard !host.isEmpty, !username.isEmpty, !command.isEmpty else {
            return "Bad host/username/command."
        }
        let auth: @Sendable () -> SSHAuthenticationMethod = {
            .passwordBased(username: username, password: password ?? "")
        }
        let settings: SSHClientSettings = {
            var s = SSHClientSettings(host: host, port: port,
                                      authenticationMethod: auth,
                                      hostKeyValidator: .acceptAnything())
            s.connectTimeout = .seconds(Int64(min(max(timeout, 5), 120)))
            return s
        }()
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let client = try await SSHClient.connect(to: settings)
                    var out: String
                    do {
                        var buf = try await client.executeCommand(command)
                        out = buf.readString(length: buf.readableBytes) ?? "(binary output)"
                    } catch {
                        try? await client.close()
                        throw error
                    }
                    try? await client.close()
                    return out
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(min(max(timeout, 5), 300) * 1_000_000_000))
                    throw ToolError.io("SSH timed out after \(timeout)s.")
                }
                guard let result = try await group.next() else { return "(no result)" }
                group.cancelAll()
                return String(result.prefix(8000))
            }
        } catch {
            return "SSH error: \(error)"
        }
    }

    // MARK: - Internal shell (JavaScriptCore)

    /// Execute JavaScript in the built-in shell. Real execution, persistent state.
    /// Swift cannot be compiled at runtime inside an app sandbox; this is the real
    /// scriptable shell the platform allows.
    private func jsRun(code: String) -> String {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Empty code."
        }
        jsBox.lock.lock()
        defer { jsBox.lock.unlock() }
        var logs: [String] = []
        let ctx = jsBox.context
        let logBlock: @convention(block) (String) -> Void = { logs.append($0) }
        ctx.setObject(logBlock, forKeyedSubscript: "print" as NSString)
        ctx.exceptionHandler = { _, exc in
            logs.append("EXCEPTION: \(exc?.toString() ?? "unknown")")
        }
        let result = ctx.evaluateScript(code)
        var out = logs.joined(separator: "\n")
        if let r = result, !r.isUndefined, !r.isNull,
           let s = r.toString(), !s.isEmpty {
            if !out.isEmpty { out += "\n" }
            out += "=> \(s)"
        }
        return out.isEmpty ? "(no output)" : String(out.prefix(6000))
    }

    // MARK: - Deep system scan (read-only)

    /// Full enumeration of everything the sandbox permits: device, sandbox cage,
    /// filesystem visibility, network interfaces, granted permissions, privilege level.
    /// Recon only. It reports the cage; breaking the cage needs a jailbreak, not an app.
    private func sysScan() async -> String {
        var r: [String] = []
        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        let fm = FileManager.default

        r.append("== DEVICE ==")
        r.append("model: \(dev.model) (\(dev.name))")
        r.append("os: \(dev.systemName) \(dev.systemVersion)")
        r.append("vendor id: \(dev.identifierForVendor?.uuidString ?? "?")")
        let pct = dev.batteryLevel < 0 ? "?" : "\(Int(dev.batteryLevel * 100))%"
        r.append("battery: \(pct)")

        r.append("== KERNEL (uname) ==")
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let release = withUnsafePointer(to: &uts.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let version = withUnsafePointer(to: &uts.version) {
            $0.withMemoryRebound(to: CChar.self, capacity: 512) { String(cString: $0) }
        }
        r.append("machine: \(machine)")
        r.append("kernel release: \(release)")
        r.append("kernel version: \(version.prefix(160))")

        r.append("== CPU / MEMORY / DISK ==")
        r.append("cpus: \(ProcessInfo.processInfo.processorCount) active \(ProcessInfo.processInfo.activeProcessorCount)")
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        r.append(String(format: "memory: %.1f GB", memGB))
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            r.append(String(format: "disk: %.1f GB free / %.1f GB total",
                            Double(free) / 1_073_741_824, Double(total) / 1_073_741_824))
        }

        r.append("== APP / SANDBOX ==")
        r.append("bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        r.append("version: \(ver) (\(build))")
        r.append("home: \(NSHomeDirectory())")
        r.append("uid/gid: \(getuid())/\(getgid()) (mobile user, no root)")

        r.append("== FILESYSTEM VISIBILITY ==")
        for path in ["/System/Library", "/System/Library/Frameworks", "/usr/lib",
                     "/usr/bin", "/bin", "/etc", "/private/var/mobile", NSHomeDirectory()] {
            if let n = try? fm.contentsOfDirectory(atPath: path).count {
                r.append("\(path): readable (\(n) entries)")
            } else if fm.fileExists(atPath: path) {
                r.append("\(path): exists, not listable")
            } else {
                r.append("\(path): denied")
            }
        }
        let probe = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/.deck_writetest")
        let writable: Bool = {
            do { try "x".write(to: probe, atomically: true, encoding: .utf8)
                 try? fm.removeItem(at: probe); return true } catch { return false }
        }()
        r.append("sandbox writable: \(writable)")

        r.append("== NETWORK INTERFACES ==")
        for (name, addr) in interfaceAddresses() {
            r.append("\(name): \(addr)")
        }

        r.append("== GRANTED PERMISSIONS ==")
        r.append("photos: \(PHPhotoLibrary.authorizationStatus(for: .readWrite))")
        let ns = await UNUserNotificationCenter.current().notificationSettings()
        r.append("notifications: alert=\(ns.alertSetting.rawValue) badge=\(ns.badgeSetting.rawValue) sound=\(ns.soundSetting.rawValue)")

        r.append("== PRIVILEGE SURFACE ==")
        r.append("sandboxed app container; no fork()/process spawn; no raw sockets;")
        r.append("no access outside container except user-granted permissions above.")
        r.append("Raising privilege needs a kernel exploit (jailbreak), not an app feature.")
        return r.joined(separator: "\n")
    }

    /// Interface name + address pairs via getifaddrs (no location/network permission needed).
    private func interfaceAddresses() -> [(String, String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = cur.pointee.ifa_flags
            if (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0,
               let addr = cur.pointee.ifa_addr {
                let fam = addr.pointee.sa_family
                if fam == UInt8(AF_INET) || fam == UInt8(AF_INET6) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let len: socklen_t = fam == UInt8(AF_INET)
                        ? socklen_t(MemoryLayout<sockaddr_in>.size)
                        : socklen_t(MemoryLayout<sockaddr_in6>.size)
                    if getnameinfo(addr, len, &host, socklen_t(NI_MAXHOST),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        result.append((String(cString: cur.pointee.ifa_name),
                                       String(cString: host)))
                    }
                }
            }
            p = cur.pointee.ifa_next
        }
        return result
    }

    // MARK: - Jailbreak operations

    /// Kernel/build fingerprint shared by the jailbreak tools. uname() is real and
    /// sandbox-safe; the XNU build string is what offset derivation needs.
    private func jailbreakFingerprint() -> (machine: String, ios: String, kernel: String, checkm8Vuln: Bool) {
        var uts = utsname()
        uname(&uts)
        func str(_ p: UnsafePointer<CChar>) -> String { String(cString: p) }
        let machine = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256, str) }
        let kernel = withUnsafePointer(to: &uts.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256, str) }
        let ios = UIDevice.current.systemVersion
        // checkm8 (bootrom) covers A11 and below = iPhone10,x and older.
        var checkm8Vuln = false
        if machine.hasPrefix("iPhone"),
           let major = Int(machine.dropFirst(6).prefix(while: { $0.isNumber })), major <= 10 {
            checkm8Vuln = true
        }
        return (machine, ios, kernel, checkm8Vuln)
    }

    /// Matches THIS build against the known-exploit database.
    /// DB date: 2026-10-08. The rooootdev watch feeds updates.
    private func jailbreakVerdict() -> (live: Bool, lines: [String]) {
        let fp = jailbreakFingerprint()
        func ver(_ s: String) -> [Int] { s.split(separator: ".").compactMap { Int($0) } }
        func le(_ a: String, _ b: String) -> Bool {
            let x = ver(a), y = ver(b)
            for i in 0..<max(x.count, y.count) {
                let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
                if p != q { return p < q }
            }
            return true
        }
        var r: [String] = []
        r.append("machine: \(fp.machine), iOS \(fp.ios), kernel \(fp.kernel)")
        r.append("checkm8-vulnerable chip: \(fp.checkm8Vuln ? "YES (A11 or older)" : "no (A12+)")")
        let db: [(String, String, Bool)] = [
            ("checkra1n / palera1n (checkm8 bootrom)", "A5-A11, any iOS", fp.checkm8Vuln),
            ("unc0ver / Taurine", "iOS <= 14.8", le(fp.ios, "14.8")),
            ("kfd-based (kernel file descriptor)", "iOS 16.0 - 16.6.1", le("16.0", fp.ios) && le(fp.ios, "16.6.1")),
            ("lara", "iOS <= 26.0.1", le(fp.ios, "26.0.1")),
            ("mond", "iOS 27.0 betas only (not final/RC)", false),
        ]
        var live = false
        for (name, coverage, ok) in db {
            r.append("\(ok ? "LIVE" : "dead"): \(name) [\(coverage)]")
            if ok { live = true }
        }
        return (live, r)
    }

    /// Jailbreak readiness report for this build.
    private func jailbreakStatus() -> String {
        let (live, lines) = jailbreakVerdict()
        var r: [String] = []
        r.append("== YOUR BUILD ==")
        r += lines
        r.append("")
        if live {
            r.append("VERDICT: exploit exists for this build.")
            r.append("Next: deck derives offsets for this exact kernel build, assembles the")
            r.append("package, then presents the full plan — mechanism, persistence model,")
            r.append("traces left behind, how it avoids Apple/kernel-guard detection, risks —")
            r.append("and STOPS for your explicit confirmation. Nothing executes without it.")
        } else {
            r.append("VERDICT: no public jailbreak for this build.")
            r.append("New bugs come from research (fuzzing pipeline / public drops), not from")
            r.append("scan data. The rooootdev watch monitors for the first real signal.")
            r.append("When one lands, the flow above activates: assemble, explain, confirm, execute.")
        }
        return r.joined(separator: "\n")
    }

    /// Builds the engineering path toward privilege, properly: every phase is grounded
    /// in scan output, fetched writeups, or CVEs. Unknown steps are marked RESEARCH
    /// with concrete next actions — never fabricated. The model drives this with
    /// sys_scan, jailbreak_status, http_fetch, and js_run as its instruments.
    private func jailbreakPath() -> String {
        let fp = jailbreakFingerprint()
        let (live, _) = jailbreakVerdict()
        var r: [String] = []
        r.append("== JAILBREAK PATH ==")
        r.append("target: \(fp.machine), iOS \(fp.ios), kernel \(fp.kernel)")
        r.append("")
        r.append("PHASE 1 — RECON: COMPLETE.")
        r.append("  sys_scan mapped the sandbox cage; the kernel fingerprint above pins the")
        r.append("  exact build. This fingerprint is what offset derivation needs — it does")
        r.append("  not invent bugs. Version numbers are labels, not vulnerabilities.")
        r.append("")
        if live {
            r.append("PHASE 2 — EXPLOIT MATCH: LIVE exploit in DB.")
            r.append("PHASE 3 — ASSEMBLE:")
            r.append("  1. Fetch the exploit source (cite it).")
            r.append("  2. Derive offsets for THIS exact kernel build (patchfinder).")
            r.append("  3. Package exploit + offsets + loader.")
            r.append("PHASE 4 — EXPLAIN + CONFIRM:")
            r.append("  Present mechanism, persistence model, traces left behind, how it")
            r.append("  avoids Apple/kernel-guard detection, and risks. Then STOP. Execute")
            r.append("  only on explicit user confirmation in chat.")
        } else {
            r.append("PHASE 2 — EXPLOIT MATCH: none for this build.")
            r.append("PHASE 3 — RESEARCH (the proper way to build an exploit):")
            r.append("  a) FUZZING (VM pipeline, proven): memory-safety bugs in userspace")
            r.append("     parsers first — AFL++ works there. Kernel driver bugs need XNU")
            r.append("     source audit plus a Mac/corellium-class target; the phone cannot")
            r.append("     fuzz (fork() is blocked by the sandbox).")
            r.append("  b) LITERATURE: http_fetch writeups and CVEs for this iOS version.")
            r.append("     Every path step must cite its source. No source = RESEARCH,")
            r.append("     never an invented step. Faking an exploit is the one unforgivable.")
            r.append("  c) WATCH: rooootdev watch runs daily; first real signal activates")
            r.append("     the LIVE branch above.")
            r.append("PHASE 4 — EXECUTE: gated exactly as in the LIVE branch.")
        }
        r.append("")
        r.append("STANDING RULES: never fake an exploit. Never execute without explicit user")
        r.append("confirmation after the full plan — including detection avoidance — is shown.")
        return r.joined(separator: "\n")
    }

    // MARK: - Uplink awareness

    /// What the system network path is right now: wifi / cellular / none, metered or not.
    /// The deck rides the system path automatically (eSIM, WiFi, or nothing) — there is
    /// nothing to configure. The brain, agent, memory, and local tools work fully offline;
    /// only web-dependent tools need an uplink.
    private func netStatus() async -> String {
        await withCheckedContinuation { cont in
            let mon = NWPathMonitor()
            mon.pathUpdateHandler = { path in
                var r: [String] = []
                switch path.status {
                case .satisfied: r.append("status: online")
                case .requiresConnection: r.append("status: captive/standby")
                default: r.append("status: offline")
                }
                var ifs: [String] = []
                if path.usesInterfaceType(.wifi) { ifs.append("wifi") }
                if path.usesInterfaceType(.cellular) { ifs.append("cellular") }
                if path.usesInterfaceType(.wiredEthernet) { ifs.append("ethernet") }
                if path.usesInterfaceType(.loopback) { ifs.append("loopback") }
                r.append("uplink: \(ifs.isEmpty ? "none" : ifs.joined(separator: "+"))")
                r.append("metered: \(path.isExpensive)")
                r.append("low-data mode: \(path.isConstrained)")
                mon.cancel()
                cont.resume(returning: r.joined(separator: "\n"))
            }
            mon.start(queue: .global())
        }
    }

    // MARK: - WiFi LAN discovery (real on-device recon)

    /// Finds live hosts on the joined WiFi /24 via TCP connect. This is the real WiFi
    /// recon an iPhone can do: no monitor mode / packet injection exists on iPhone
    /// radios for apps, so deauth/handshake-sniffing is NOT a phone job — that needs
    /// an external radio driven over ssh_exec. Phone = brain, external radio = hands.
    private func lanScan() async -> String {
        var ipRaw: UInt32 = 0
        var maskRaw: UInt32 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "getifaddrs failed." }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if String(cString: cur.pointee.ifa_name) == "en0",
               let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               let mask = cur.pointee.ifa_netmask {
                ipRaw = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                maskRaw = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                break
            }
            p = cur.pointee.ifa_next
        }
        guard ipRaw != 0, maskRaw != 0 else { return "Not on WiFi (no en0 IPv4)." }
        let network = ipRaw & maskRaw
        let broadcast = network | ~maskRaw
        var targets: [UInt32] = []
        var h = network + 1
        while h < broadcast, targets.count < 512 {
            if h != ipRaw { targets.append(h) }
            h += 1
        }
        @Sendable func dotted(_ v: UInt32) -> String {
            // s_addr is network byte order; convert to host order before shifting,
            // otherwise octets come out reversed on little-endian (all iPhones).
            let h = UInt32(bigEndian: v)
            "\((h >> 24) & 0xFF).\((h >> 16) & 0xFF).\((h >> 8) & 0xFF).\(h & 0xFF)"
        }
        let ports = ["22", "80", "443"]
        let found = await withTaskGroup(of: (String, [String]).self, returning: [(String, [String])].self) { group in
            for t in targets {
                group.addTask {
                    let host = dotted(t)
                    var open: [String] = []
                    for pt in ports {
                        if await self.tcpConnect(host: host, port: pt, timeout: 0.8).hasPrefix("OPEN") {
                            open.append(pt)
                        }
                    }
                    return (host, open)
                }
            }
            var out: [(String, [String])] = []
            for await (host, open) in group where !open.isEmpty { out.append((host, open)) }
            return out
        }
        if found.isEmpty { return "No live hosts found on \(dotted(network))/24." }
        let lines = found.sorted { $0.0 < $1.0 }
            .map { "\($0.0): \($0.1.joined(separator: ","))" }
        return "LIVE HOSTS on \(dotted(network))/24:\n" + lines.joined(separator: "\n")
    }

    // MARK: - On-device reverse engineering (light static analysis)

    /// Static analysis of a Mach-O binary: headers, segments, imported dylibs,
    /// entry point, strings. Works on the deck folder, the app's own binary
    /// ("self"), or absolute device paths (/usr/lib/dyld, /System/Library/...).
    /// This is the real on-device RE slice: no decompiler fits on a
    /// phone (Ghidra/Hopper/IDA need desktop engines + GBs of RAM). Heavy lifting
    /// — decompile, call graphs, xrefs — runs via REA on a remote box over ssh_exec.
    private func binInfo(path: String) -> String {
        let url: URL
        if path == "self" {
            guard let eurl = Bundle.main.executableURL else { return "No executable URL." }
            url = eurl
        } else if path.hasPrefix("/") {
            // Device binaries: the read-only system volume (dyld, frameworks).
            // Reads only — the sandbox forbids writes there anyway.
            url = URL(fileURLWithPath: path)
        } else {
            do { url = try jailed(path) } catch { return "Bad path: \(error)" }
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return "Cannot read file."
        }
        func u32(_ o: Int) -> UInt32? {
            guard o + 4 <= data.count else { return nil }
            let b0 = UInt32(data[o]), b1 = UInt32(data[o + 1])
            let b2 = UInt32(data[o + 2]), b3 = UInt32(data[o + 3])
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }
        func u32be(_ o: Int) -> UInt32? {
            guard let v = u32(o) else { return nil }
            return v.byteSwapped
        }
        func u64(_ o: Int) -> UInt64? {
            guard let lo = u32(o), let hi = u32(o + 4) else { return nil }
            return UInt64(lo) | (UInt64(hi) << 32)
        }
        func cstr(_ o: Int, max: Int) -> String? {
            guard o < data.count else { return nil }
            var end = o
            while end < data.count && end < o + max && data[end] != 0 { end += 1 }
            return String(bytes: data[o..<end], encoding: .utf8)
        }
        var r: [String] = []
        guard let magic = u32(0) else { return "Too small." }

        // FAT binary: list contained architectures.
        if u32be(0) == 0xcafebabe {
            guard let n = u32be(4) else { return "Truncated fat header." }
            r.append("fat binary, \(n) architectures:")
            for i in 0..<min(n, 8) {
                let o = 8 + Int(i) * 20
                guard let cput = u32be(o), let off = u32be(o + 8), let sz = u32be(o + 12) else { break }
                let arch = cput == 0x0100000C ? "arm64" : cput == 0x01000007 ? "x86_64" : String(format: "0x%x", cput)
                r.append("  \(arch) @0x\(String(off, radix: 16)) (\(sz) bytes)")
            }
            return r.joined(separator: "\n")
        }
        guard magic == 0xfeedfacf || magic == 0xfeedface else {
            return String(format: "Not Mach-O (magic 0x%x).", magic)
        }
        let is64 = magic == 0xfeedfacf
        let cput = u32(4) ?? 0, ftype = u32(12) ?? 0, ncmds = u32(16) ?? 0
        let arch = cput == 0x0100000C ? "arm64" : cput == 0x01000007 ? "x86_64" : String(format: "cpu 0x%x", cput)
        let ftn: String
        switch ftype {
        case 0x2: ftn = "executable"
        case 0x6: ftn = "dylib"
        case 0x8: ftn = "bundle"
        default: ftn = String(format: "type 0x%x", ftype)
        }
        r.append("mach-o \(is64 ? "64" : "32")-bit \(arch) \(ftn), \(ncmds) load commands")

        var segs: [String] = []
        var dylibs: [String] = []
        var entry: String = "?"
        var off = 32
        for _ in 0..<min(ncmds, 200) {
            guard let cmd = u32(off), let csz = u32(off + 4), csz >= 8 else { break }
            switch cmd {
            case 0x19: // LC_SEGMENT_64
                if let name = cstr(off + 8, max: 16) { segs.append(name) }
            case 0x1: // LC_SEGMENT (32-bit)
                if let name = cstr(off + 8, max: 16) { segs.append(name) }
            case 0xC, 0x18, 0x80000022, 0x80000024: // LC_LOAD_DYLIB & friends
                if let no = u32(off + 8), let name = cstr(off + Int(no), max: 256) {
                    dylibs.append((name as NSString).lastPathComponent)
                }
            case 0x80000028: // LC_MAIN
                if let eo = u64(off + 8) { entry = "0x\(String(eo, radix: 16))" }
            default: break
            }
            off += Int(csz)
            if off >= data.count { break }
        }
        r.append("segments: \(segs.joined(separator: ", "))")
        r.append("entry: \(entry)")
        r.append("dylibs (\(dylibs.count)): \(dylibs.joined(separator: ", "))")

        // Strings pass: printable runs >= 5 chars, unique, capped.
        var seen = Set<String>()
        var strs: [String] = []
        var run: [UInt8] = []
        func flush() {
            if run.count >= 5 {
                let s = String(bytes: run, encoding: .utf8) ?? ""
                if !s.isEmpty && seen.insert(s).inserted && strs.count < 300 { strs.append(s) }
            }
            run.removeAll(keepingCapacity: true)
        }
        for b in data {
            if b >= 0x20 && b < 0x7F { run.append(b) } else { flush() }
        }
        flush()
        r.append("strings (\(strs.count) unique, capped):")
        let body = strs.joined(separator: "\n")
        r.append(String(body.prefix(4000)))
        return r.joined(separator: "\n")
    }

    // MARK: - Social reach (no-login platforms, on-device)

    /// Read/search the parts of the internet that need no login: reddit (public
    /// search.json), github (public API), v2ex (hot topics), rss (any feed).
    /// Read-only. Login-backed platforms (twitter/X, instagram, facebook, youtube
    /// transcripts, xiaohongshu, bilibili...) need Agent-Reach on a real box —
    /// drive it over ssh_exec. Never invent posts; quote what was fetched.
    private func socialSearch(platform: String, query: String) async -> String {
        switch platform.lowercased() {
        case "reddit": return await redditSearch(query: query)
        case "github": return await githubSearch(query: query)
        case "v2ex": return await v2exHot()
        case "rss": return await rssRead(urlString: query)
        default:
            return "On-device platforms: reddit, github, v2ex, rss. "
                + "The full 16-platform suite (twitter/X, instagram, facebook, youtube, "
                + "xiaohongshu, bilibili, linkedin...) runs via Agent-Reach on a remote "
                + "box over ssh_exec."
        }
    }

    private func fetchJSON(_ urlString: String, accept: String? = nil) async -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Deck/1.0 (iOS; agent)", forHTTPHeaderField: "User-Agent")
        if let a = accept { req.setValue(a, forHTTPHeaderField: "Accept") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func redditSearch(query: String) async -> String {
        guard !query.isEmpty else { return "Empty query." }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let json = await fetchJSON("https://www.reddit.com/search.json?q=\(q)&limit=10&sort=relevance"),
              let data = (json as? [String: Any])?["data"] as? [String: Any],
              let children = data["children"] as? [[String: Any]] else {
            return "Reddit fetch failed (rate-limited or offline)."
        }
        var out: [String] = []
        for c in children.prefix(10) {
            guard let d = c["data"] as? [String: Any],
                  let title = d["title"] as? String else { continue }
            let sub = d["subreddit_name_prefixed"] as? String ?? ""
            let score = d["score"] as? Int ?? 0
            let comments = d["num_comments"] as? Int ?? 0
            let link = d["url"] as? String ?? ""
            var selftext = (d["selftext"] as? String ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            if selftext.count > 300 { selftext = String(selftext.prefix(300)) + "…" }
            out.append("• [\(sub)] \(title) (▲\(score), \(comments) comments)\n  \(link)"
                + (selftext.isEmpty ? "" : "\n  \(selftext)"))
        }
        return out.isEmpty ? "No results." : out.joined(separator: "\n\n")
    }

    private func githubSearch(query: String) async -> String {
        guard !query.isEmpty else { return "Empty query." }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let json = await fetchJSON(
                "https://api.github.com/search/repositories?q=\(q)&per_page=5&sort=stars",
                accept: "application/vnd.github+json"),
              let items = (json as? [String: Any])?["items"] as? [[String: Any]] else {
            return "GitHub fetch failed (rate-limited or offline)."
        }
        var out: [String] = []
        for it in items.prefix(5) {
            let name = it["full_name"] as? String ?? "?"
            let desc = (it["description"] as? String ?? "").prefix(200)
            let stars = it["stargazers_count"] as? Int ?? 0
            let url = it["html_url"] as? String ?? ""
            out.append("• \(name) ★\(stars)\n  \(url)\n  \(desc)")
        }
        return out.isEmpty ? "No results." : out.joined(separator: "\n\n")
    }

    private func v2exHot() async -> String {
        guard let json = await fetchJSON("https://www.v2ex.com/api/topics/hot.json"),
              let topics = json as? [[String: Any]] else {
            return "V2EX fetch failed."
        }
        var out: [String] = []
        for tp in topics.prefix(10) {
            let title = tp["title"] as? String ?? "?"
            let url = tp["url"] as? String ?? ""
            let replies = tp["replies"] as? Int ?? 0
            let node = (tp["node"] as? [String: Any])?["title"] as? String ?? ""
            out.append("• [\(node)] \(title) (\(replies) replies)\n  https://www.v2ex.com\(url)")
        }
        return out.isEmpty ? "No topics." : out.joined(separator: "\n\n")
    }

    private func rssRead(urlString: String) async -> String {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return "Bad feed URL." }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Deck/1.0 (iOS; agent)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else {
            return "Feed fetch failed."
        }
        var out: [String] = []
        let itemPat = "<item[ >].*?</item>"
        let items = (try? NSRegularExpression(pattern: itemPat, options: [.dotMatchesLineSeparators]))
            .map { rx in rx.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
                .compactMap { Range($0.range, in: xml).map { String(xml[$0]) } } } ?? []
        func tag(_ name: String, in s: String) -> String {
            guard let rx = try? NSRegularExpression(pattern: "<\(name)[ >].*?</\(name)>",
                                                   options: [.dotMatchesLineSeparators]),
                  let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range, in: s) else { return "" }
            return String(s[r]).replacingOccurrences(of: "<[^>]+>", with: "",
                                                     options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for it in items.prefix(10) {
            let title = tag("title", in: it)
            let link = tag("link", in: it)
            if !title.isEmpty { out.append("• \(title)\n  \(link)") }
        }
        return out.isEmpty ? "No items parsed." : out.joined(separator: "\n\n")
    }

    // MARK: - Skills (mattpocock/skills playbooks, bundled offline)

    /// The bundled skill library: name -> {description, body}. Parsed on demand;
    /// small enough that no caching (and no shared mutable state) is needed.
    private func skillBook() -> [String: [String: Any]] {
        var book: [String: [String: Any]] = [:]
        for res in ["skills1", "skills2"] {
            guard let url = Bundle.main.url(forResource: res, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                continue
            }
            for (k, v) in obj { book[k] = v }
        }
        return book
    }

    private func listSkills() -> String {
        let book = skillBook()
        if book.isEmpty { return "Skill library not bundled." }
        let lines = book.keys.sorted().map { k -> String in
            let d = (book[k]?["description"] as? String) ?? ""
            let mi = (book[k]?["model_invoked"] as? Bool) ?? true
            return "- \(k): \(d)" + (mi ? "" : " [upstream marks user-invoked]")
        }
        return "SKILLS (\(book.count)) — call use_skill {\"name\": \"<skill>\"} to load a playbook:\n"
            + lines.joined(separator: "\n")
    }

    private func useSkill(name: String) -> String {
        let book = skillBook()
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let match = book.keys.first { $0.lowercased() == key || $0.lowercased().hasSuffix("/" + key) }
        guard let m = match, let body = book[m]?["body"] as? String else {
            return "Unknown skill \(name). Call list_skills {} for the catalog."
        }
        return "SKILL PLAYBOOK: \(m) — follow it now.\n\n" + String(body.prefix(9000))
    }

    // MARK: - Tradecraft library (Book of Secret Knowledge, bundled offline)

    /// Search the bundled tradecraft bible: pentest methodology, tool references,
    /// networking, cheat sheets, shell tradecraft. Offline, no API, no login.
    /// Note: the bash one-liners don't execute here (no bash; js_run is JavaScript)
    /// but the techniques transfer.
    private func bookSearch(query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "Empty query." }
        var book: [String: String] = [:]
        for res in ["book1", "book2"] {
            guard let url = Bundle.main.url(forResource: res, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                continue
            }
            for (k, v) in obj { book[k] = v }
        }
        if book.isEmpty { return "Tradecraft library not bundled." }
        var hits: [String] = []
        outer: for chapter in book.keys.sorted() {
            let ns = book[chapter]! as NSString
            var searchRange = NSRange(location: 0, length: ns.length)
            var count = 0
            while count < 3 {
                let found = ns.range(of: q, options: .caseInsensitive, range: searchRange)
                if found.location == NSNotFound { break }
                let start = max(0, found.location - 300)
                let end = min(ns.length, found.location + found.length + 300)
                hits.append("[\(chapter)] …\(ns.substring(with: NSRange(location: start, length: end - start)))…")
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: ns.length - next)
                count += 1
                if hits.count >= 6 { break outer }
            }
        }
        if hits.isEmpty { return "No matches for \(q)." }
        return String(hits.joined(separator: "\n\n").prefix(6000))
    }

    // MARK: - General web search (DuckDuckGo HTML — keyless, no account, no API)

    /// Keyless general web search via the DDG HTML endpoint. Fills the gap between
    /// social_search (Reddit/GitHub/V2EX/RSS) and http_fetch (needs an exact URL).
    private func webSearch(query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "Empty query." }
        guard var comps = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            return "Bad URL."
        }
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = comps.url else { return "Bad query." }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else {
            return "Web search failed (network error or blocked)."
        }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let linkRe = try? NSRegularExpression(
                pattern: "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>",
                options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let snipRe = try? NSRegularExpression(
                pattern: "<a[^>]*class=\"result__snippet\"[^>]*>(.*?)</a>",
                options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return "Search parser unavailable."
        }
        let links = linkRe.matches(in: html, range: full)
        let snips = snipRe.matches(in: html, range: full)
        func stripTags(_ s: String) -> String {
            s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
             .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: [String] = []
        for (i, m) in links.prefix(8).enumerated() {
            guard m.numberOfRanges > 2,
                  let hr = Range(m.range(at: 1), in: html),
                  let tr = Range(m.range(at: 2), in: html) else { continue }
            var href = String(html[hr])
            // Unwrap DDG's redirect: //duckduckgo.com/l/?uddg=<encoded-url>
            let abs = href.hasPrefix("//") ? "https:" + href : href
            if let u = URL(string: abs),
               let c2 = URLComponents(url: u, resolvingAgainstBaseURL: false),
               let uddg = c2.queryItems?.first(where: { $0.name == "uddg" })?.value,
               let decoded = uddg.removingPercentEncoding, !decoded.isEmpty {
                href = decoded
            }
            let title = stripTags(String(html[tr]))
            var snippet = ""
            if i < snips.count, snips[i].numberOfRanges > 1,
               let sr = Range(snips[i].range(at: 1), in: html) {
                snippet = stripTags(String(html[sr]))
            }
            out.append("\(i + 1). \(title)\n   \(href)"
                       + (snippet.isEmpty ? "" : "\n   \(snippet.prefix(220))"))
        }
        if out.isEmpty { return "No results for \(q)." }
        return out.joined(separator: "\n\n")
    }

    // MARK: - MCP client (hand-rolled JSON-RPC 2.0 over Streamable HTTP)

    /// Minimal MCP client: talks to any Streamable-HTTP MCP server.
    /// op="list" → tool inventory; op="call" → invoke a tool.
    /// No subprocesses (sandbox), so stdio servers are out of reach by design.
    /// Pure URLSession + JSONSerialization: no SDK, no license risk.
    private func mcpCall(server: String, op: String, tool: String,
                         arguments: String) async -> String {
        let base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: base),
              url.scheme == "https" || url.scheme == "http" else {
            return "MCP error: bad server URL (need http(s)://…)."
        }
        // Best-effort handshake; many servers answer calls without it.
        _ = await mcpPost(url: url, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Deck", "version": "1.0"],
        ])
        _ = await mcpPost(url: url, method: "notifications/initialized",
                          params: [:], notify: true)

        if op.lowercased() == "call" {
            guard !tool.isEmpty else { return "MCP error: op=call needs a tool name." }
            var argObj: [String: Any] = [:]
            let tm = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tm.isEmpty {
                guard let data = tm.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                    return "MCP error: arguments is not a JSON object."
                }
                argObj = obj
            }
            let res = await mcpPost(url: url, method: "tools/call",
                                    params: ["name": tool, "arguments": argObj])
            return mcpText(from: res, cap: 6000)
        }

        let res = await mcpPost(url: url, method: "tools/list", params: [:])
        guard let result = res["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return "MCP error: no tools in response."
        }
        if tools.isEmpty { return "(server exposes no tools)" }
        let lines = tools.prefix(20).map { item -> String in
            let n = item["name"] as? String ?? "(unnamed)"
            let d = (item["description"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? "- \(n)" : "- \(n): \(String(d.prefix(160)))"
        }
        return lines.joined(separator: "\n")
    }

    /// One JSON-RPC POST. Returns the parsed envelope (or [:] on any failure).
    /// Accepts plain JSON and SSE-wrapped ("data: …") bodies.
    private func mcpPost(url: URL, method: String, params: [String: Any],
                         notify: Bool = false) async -> [String: Any] {
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method,
                                      "params": params]
        if !notify { payload["id"] = 1 }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return [:]
        }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              !data.isEmpty else { return [:] }
        return mcpParse(data: data)
    }

    /// Extract the JSON-RPC envelope from a plain-JSON or SSE body.
    private func mcpParse(data: Data) -> [String: Any] {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var last: [String: Any] = [:]
        for line in text.components(separatedBy: .newlines) {
            let tm = line.trimmingCharacters(in: .whitespaces)
            guard tm.hasPrefix("data:") else { continue }
            let payload = tm.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d)
                    as? [String: Any] else { continue }
            last = obj
        }
        return last
    }

    /// Render a tools/call result's content blocks as text, capped.
    private func mcpText(from envelope: [String: Any], cap: Int) -> String {
        if let err = envelope["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "unknown error"
            return "MCP error: \(msg)"
        }
        guard let result = envelope["result"] as? [String: Any] else {
            return "MCP error: empty result."
        }
        if let content = result["content"] as? [[String: Any]] {
            let parts = content.compactMap { $0["text"] as? String }
            let text = parts.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "(empty content)" : String(text.prefix(cap))
        }
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let s = String(data: data, encoding: .utf8) {
            return String(s.prefix(cap))
        }
        return "(unreadable result)"
    }

    // MARK: - Vision (on-demand, via VisionEngine)

    /// Actually look at an image. path="latest" (or empty) = newest screenshot.
    private func seeImage(path: String, prompt: String) async -> String {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: String
        if p.isEmpty || p.lowercased() == "latest" {
            guard let url = ScreenMemory.shared.latestURL() else {
                return "No screenshots captured yet."
            }
            target = url.path
        } else {
            target = p
        }
        return await VisionEngine.shared.describe(imagePath: target, prompt: prompt)
    }
}
