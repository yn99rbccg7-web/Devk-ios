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
        "ssh_exec", "js_run", "sys_scan", "jailbreak_status", "jailbreak_path",
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
                                 privateKey: args["privateKey"],
                                 command: args["command"] ?? "",
                                 timeout: Double(args["timeout"] ?? "") ?? 30)

        case "js_run":
            return jsRun(code: args["code"] ?? "")

        case "sys_scan":
            return await sysScan()

        case "jailbreak_path":
            return jailbreakPath()

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

    /// Run a command on a remote server. Auth: password, or OpenSSH ed25519 private key string.
    /// Host key is accepted on first connection (TOFU pinning is future work).
    /// Credentials should live in the deck's memory store, not pasted into chat.
    private func sshExec(host: String, port: Int, username: String, password: String?,
                         privateKey: String?, command: String, timeout: Double) async -> String {
        guard !host.isEmpty, !username.isEmpty, !command.isEmpty else {
            return "Bad host/username/command."
        }
        let auth: @Sendable () -> SSHAuthenticationMethod = {
            if let key = privateKey, !key.isEmpty,
               let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: key) {
                return .ed25519(username: username, privateKey: ed)
            }
            return .passwordBased(username: username, password: password ?? "")
        }
        var settings = SSHClientSettings(host: host, port: port,
                                         authenticationMethod: auth,
                                         hostKeyValidator: .acceptAnything())
        settings.connectTimeout = .seconds(Int64(min(max(timeout, 5), 120)))
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
}
