//
//  ProxyAttributor.swift
//  ITrafficMonitorForMac
//
//  Pierces through Clash/Surge local proxies so proxied traffic is
//  attributed back to the real apps instead of the proxy process.
//
//  Why this is needed: `nettop -P -t external` credits bytes to the
//  process that owns the outbound socket on the external interface.
//  When a local proxy / VPN (ClashX, Clash Verge, Mihomo, Surge, ...)
//  is active it owns those sockets, so every byte lands on the proxy
//  process while the real apps show zero (their app→proxy traffic is
//  loopback and excluded by `-t external`).
//
//  How this pierces the proxy:
//   1. Poll the proxy's own connection table every 2s:
//        Clash: GET http://127.0.0.1:9090/connections
//        Surge: GET http://127.0.0.1:6171/v1/connections
//      Each connection reports `metadata.sourcePort` (the client app's
//      local port on this Mac) plus session-cumulative `upload`/`download`.
//   2. Map source port → owning pid with `lsof` socket-table snapshots
//      (TCP ESTABLISHED + UDP), which covers both system-proxy mode and
//      TUN mode (the source port is the client's real local port either way).
//   3. Compute per-connection byte deltas between polls and aggregate them
//      per app pid. The proxy process keeps only its own uncarried bytes.
//
//  Threading: a serial `proxy-attributor` queue owns the timer and all
//  polling/lsof work. `pendingCredits`/`proxyPid`/`pidNameCache` are
//  written there and read from the nettop runner queue via
//  `attributedEntities(_:)`, guarded by `stateLock`. We never block the
//  nettop queue on lsof or HTTP.
//

import Foundation
import Combine

enum ProxyStatus: Equatable {
    case disabled
    case detected(name: String)
    case notDetected
    case secretRequired
}

/// Normalized proxy connection: `sourcePort` is the client app's local port.
private struct ProxyConnection {
    let id: String
    let sourcePort: Int
    let upload: Int64
    let download: Int64
}

/// One tracked connection. Byte totals are session-cumulative; `pid` is the
/// app resolved via lsof at the tick this snapshot was captured (so the NEXT
/// tick can attribute that interval's delta).
private struct TrackedConnection {
    let pid: Int
    let sourcePort: Int
    let uploadTotal: Int64
    let downloadTotal: Int64
}

final class ProxyAttributor: ObservableObject {

    @Published private(set) var status: ProxyStatus = .disabled

    // MARK: - State shared with the nettop runner queue (locked)

    private let stateLock = NSLock()
    /// Bytes to credit back to apps (keyed by pid) from the most recent tick.
    private var pendingCredits: [Int: (inBytes: Int, outBytes: Int)] = [:]
    /// The proxy process pid (owns the external-controller listening socket).
    private var proxyPid: Int?
    /// pid -> process name from lsof, used as a fallback name for new entities.
    private var pidNameCache: [Int: String] = [:]

    // MARK: - Attributor-queue state (no lock)

    private let queue = DispatchQueue(label: "proxy-attributor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previousConnections: [String: TrackedConnection] = [:]

    private let interval = 2 // seconds, matches nettop cadence

    // MARK: - Config

    private enum ProxyType {
        case off, auto, clash, surge
    }

    private struct Config {
        let enabled: Bool
        let type: ProxyType
        let baseURL: String
        let secret: String
    }

    private struct Candidate {
        let baseURL: String
        let path: String
        let port: Int
        let name: String
    }

    private enum DetectResult {
        case success(Candidate, [ProxyConnection])
        case secretRequired
        case notFound
    }

    // MARK: - Public API

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .seconds(self.interval))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.reset()
        }
    }

    /// Re-read settings and run an immediate detection tick (used by Settings).
    func reconfigure() {
        queue.async { [weak self] in
            self?.tick()
        }
    }

    /// Called on the nettop runner queue. Re-distributes the proxy process's
    /// bytes to the real apps using the latest computed credits. Cheap: only
    /// takes a locked snapshot and transforms the entity array.
    func attributedEntities(_ raw: [ProcessEntity]) -> [ProcessEntity] {
        let snapshot = takeCreditsSnapshot()
        guard !snapshot.credits.isEmpty, let proxyPid = snapshot.proxyPid else {
            return raw
        }

        // Locate the proxy entity in this frame (it may be absent if the
        // frame window and the attributor tick are out of phase).
        var proxyIndex: Int?
        for (i, e) in raw.enumerated() where e.pid == proxyPid {
            proxyIndex = i
            break
        }
        let proxyIn = proxyIndex.map { raw[$0].inBytes } ?? 0
        let proxyOut = proxyIndex.map { raw[$0].outBytes } ?? 0

        let totalIn = snapshot.credits.values.reduce(0) { $0 + $1.inBytes }
        let totalOut = snapshot.credits.values.reduce(0) { $0 + $1.outBytes }

        // Direction-level cap: when the proxy entity is visible in the same
        // frame, apps are never credited more than the proxy actually carried
        // (guards against API-payload vs wire-bytes drift). When it is absent
        // (phase mismatch), credits apply in full and the next frame balances.
        let scaleIn = proxyIn > 0 && totalIn > proxyIn ? Double(proxyIn) / Double(totalIn) : 1.0
        let scaleOut = proxyOut > 0 && totalOut > proxyOut ? Double(proxyOut) / Double(totalOut) : 1.0

        var creditedIn: [Int: Int] = [:]
        var creditedOut: [Int: Int] = [:]
        for (pid, c) in snapshot.credits where pid != proxyPid {
            let scaledIn = Int(Double(c.inBytes) * scaleIn)
            let scaledOut = Int(Double(c.outBytes) * scaleOut)
            if scaledIn > 0 || scaledOut > 0 {
                creditedIn[pid] = scaledIn
                creditedOut[pid] = scaledOut
            }
        }
        let sumIn = creditedIn.values.reduce(0, +)
        let sumOut = creditedOut.values.reduce(0, +)
        guard sumIn > 0 || sumOut > 0 else { return raw }

        var result: [ProcessEntity] = []
        var existingByPid: [Int: Int] = [:]

        for (i, e) in raw.enumerated() {
            var entity = e
            if i == proxyIndex {
                // Proxy keeps only its own uncarried bytes.
                entity.inBytes = e.inBytes - min(e.inBytes, sumIn)
                entity.outBytes = e.outBytes - min(e.outBytes, sumOut)
            } else if let addIn = creditedIn[e.pid], let addOut = creditedOut[e.pid] {
                entity.inBytes = e.inBytes + addIn
                entity.outBytes = e.outBytes + addOut
                existingByPid[e.pid] = i
            }
            result.append(entity)
        }

        // New entities for apps that had zero external traffic (e.g. apps
        // behind a system-proxy that never touch the external interface
        // directly). getAppInfo resolves the proper icon/bundle id.
        let names = pidNamesSnapshot()
        for (pid, addIn) in creditedIn where existingByPid[pid] == nil {
            let addOut = creditedOut[pid] ?? 0
            let name = names[pid] ?? "\(pid)"
            result.append(ProcessEntity(pid: pid, name: name, inBytes: addIn, outBytes: addOut))
        }
        return result
    }

    // MARK: - Tick pipeline (attributor queue)

    private func tick() {
        let cfg = readConfig()
        guard cfg.enabled, cfg.type != .off else {
            reset()
            emitStatus(.disabled)
            return
        }
        let candidates = candidates(for: cfg)
        guard !candidates.isEmpty else {
            reset()
            emitStatus(.disabled)
            return
        }

        switch tryDetect(candidates, secret: cfg.secret) {
        case .success(let c, let connections):
            applyDetection(candidate: c, connections: connections)
            emitStatus(.detected(name: c.name))
        case .secretRequired:
            reset()
            emitStatus(.secretRequired)
        case .notFound:
            reset()
            emitStatus(.notDetected)
        }
    }

    private func applyDetection(candidate: Candidate, connections: [ProxyConnection]) {
        let portMap = socketPortMap()
        let proxyPid = resolveProxyPid(port: candidate.port)
        let prev = previousConnections

        var credits: [Int: (inBytes: Int, outBytes: Int)] = [:]
        var newPrevious: [String: TrackedConnection] = [:]

        for conn in connections {
            let pid = portMap.ports[conn.sourcePort] ?? 0
            newPrevious[conn.id] = TrackedConnection(
                pid: pid,
                sourcePort: conn.sourcePort,
                uploadTotal: conn.upload,
                downloadTotal: conn.download
            )
            guard let prevConn = prev[conn.id] else { continue }
            let dIn = conn.download - prevConn.downloadTotal
            let dOut = conn.upload - prevConn.uploadTotal
            if (dIn > 0 || dOut > 0), prevConn.pid > 0, prevConn.pid != proxyPid {
                var c = credits[prevConn.pid] ?? (inBytes: 0, outBytes: 0)
                c.inBytes += Int(dIn)
                c.outBytes += Int(dOut)
                credits[prevConn.pid] = c
            }
            // prevConn.pid == proxyPid → the proxy's own direct connection,
            // not tunneled traffic; keep it on the proxy.
        }

        previousConnections = newPrevious
        stateLock.lock()
        pendingCredits = credits
        self.proxyPid = proxyPid
        pidNameCache.merge(portMap.names) { _, new in new }
        stateLock.unlock()
    }

    // MARK: - Detection / fetch

    private func candidates(for cfg: Config) -> [Candidate] {
        let base = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            // Custom base URL overrides the built-in defaults.
            let port = URL(string: base)?.port ?? (cfg.type == .surge ? 6171 : 9090)
            let path = cfg.type == .surge ? "/v1/connections" : "/connections"
            let name = cfg.type == .surge ? "Surge" : "Clash"
            return [Candidate(baseURL: base, path: path, port: port, name: name)]
        }
        switch cfg.type {
        case .clash:
            // Clash (9090) and Clash Verge / Mihomo (9097) use the same
            // /connections shape; probe both so either is detected in auto.
            return [
                Candidate(baseURL: "http://127.0.0.1:9090", path: "/connections", port: 9090, name: "Clash"),
                Candidate(baseURL: "http://127.0.0.1:9097", path: "/connections", port: 9097, name: "Clash Verge"),
            ]
        case .surge:
            return [Candidate(baseURL: "http://127.0.0.1:6171", path: "/v1/connections", port: 6171, name: "Surge")]
        case .auto:
            return [
                Candidate(baseURL: "http://127.0.0.1:9090", path: "/connections", port: 9090, name: "Clash"),
                Candidate(baseURL: "http://127.0.0.1:9097", path: "/connections", port: 9097, name: "Clash Verge"),
                Candidate(baseURL: "http://127.0.0.1:6171", path: "/v1/connections", port: 6171, name: "Surge"),
            ]
        case .off:
            return []
        }
    }

    private func tryDetect(_ candidates: [Candidate], secret: String) -> DetectResult {
        var sawAuthRequired = false
        for c in candidates {
            switch fetch(c.baseURL + c.path, secret: secret) {
            case .authRequired:
                sawAuthRequired = true
            case .ok(let connections):
                // fetch() only returns .ok for a non-empty table.
                return .success(c, connections)
            case .failed:
                continue
            }
        }
        return sawAuthRequired ? .secretRequired : .notFound
    }

    private enum FetchResult {
        case ok([ProxyConnection])
        case authRequired
        case failed
    }

    private func fetch(_ urlString: String, secret: String) -> FetchResult {
        guard let url = URL(string: urlString) else { return .failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let sem = DispatchSemaphore(value: 0)
        var statusCode: Int?
        var data: Data?
        URLSession.shared.dataTask(with: request) { d, response, _ in
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
            }
            data = d
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.0)

        if statusCode == 401 || statusCode == 403 {
            return .authRequired
        }
        guard statusCode == 200, let data, let conns = decodeConnections(data), !conns.isEmpty else {
            return .failed
        }
        return .ok(conns)
    }

    /// Decodes both the Clash shape (metadata.sourcePort / upload / download)
    /// and the Surge shape (source.port / bytes.up / bytes.down).
    private func decodeConnections(_ data: Data) -> [ProxyConnection]? {
        struct Raw: Decodable {
            struct C: Decodable {
                struct Metadata: Decodable { let sourcePort: String? }
                struct Source: Decodable { let port: Int? }
                struct Bytes: Decodable { let up: Int?; let down: Int? }
                let id: String?
                let metadata: Metadata?
                let upload: Int?
                let download: Int?
                let source: Source?
                let bytes: Bytes?
            }
            let connections: [C]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let conns = raw.connections else { return nil }
        var out: [ProxyConnection] = []
        for c in conns {
            guard let id = c.id else { continue }
            let port = c.metadata?.sourcePort.flatMap(Int.init) ?? c.source?.port
            guard let port else { continue }
            out.append(ProxyConnection(
                id: id,
                sourcePort: port,
                upload: Int64(c.upload ?? c.bytes?.up ?? 0),
                download: Int64(c.download ?? c.bytes?.down ?? 0)
            ))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Socket table (lsof)

    private func runLsof(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-w"] + args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return nil
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: output, encoding: .utf8)
    }

    private func socketPortMap() -> (ports: [Int: Int], names: [Int: String]) {
        var ports: [Int: Int] = [:]
        var names: [Int: String] = [:]
        if let tcp = runLsof(["-nP", "-iTCP", "-sTCP:ESTABLISHED"]) {
            collectSocketLines(tcp, into: &ports, names: &names)
        }
        if let udp = runLsof(["-nP", "-iUDP"]) {
            collectSocketLines(udp, into: &ports, names: &names)
        }
        return (ports, names)
    }

    private func collectSocketLines(_ output: String, into ports: inout [Int: Int], names: inout [Int: String]) {
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int(fields[1]) else { continue }
            if names[pid] == nil {
                names[pid] = String(fields[0])
            }
            guard fields.count >= 9 else { continue }
            let name = fields[8...].joined(separator: " ")
            if let port = localPort(from: name), ports[port] == nil {
                ports[port] = pid
            }
        }
    }

    /// Extracts the local port from an lsof NAME column, e.g.
    ///   "TCP 127.0.0.1:54000->127.0.0.1:7890 (ESTABLISHED)"   → 54000
    ///   "TCP [::1]:9090 (LISTEN)"                              → 9090
    ///   "UDP 192.168.1.5:54000"                                → 54000
    private func localPort(from name: String) -> Int? {
        if let arrow = name.range(of: "->") {
            let localPart = name[..<arrow.lowerBound]
            guard let colon = localPart.lastIndex(of: ":") else { return nil }
            return Int(localPart[localPart.index(after: colon)...])
        }
        for token in name.split(separator: " ") where token.contains(":") {
            guard let colon = token.lastIndex(of: ":") else { continue }
            let portStr = token[token.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "(),;"))
            if let p = Int(portStr) { return p }
        }
        return nil
    }

    /// PID of the process listening on the external-controller port.
    private func resolveProxyPid(port: Int) -> Int? {
        guard let output = runLsof(["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]) else { return nil }
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2, let pid = Int(fields[1]) {
                return pid
            }
        }
        return nil
    }

    // MARK: - Config / state helpers

    private func readConfig() -> Config {
        let d = UserDefaults.standard
        // Default enabled: the whole point of this feature is to fix VPN /
        // proxy attribution, and auto-detect gracefully no-ops without a proxy.
        let enabled = d.object(forKey: "proxyAttributionEnabled") as? Bool ?? true
        let type: ProxyType
        switch d.string(forKey: "proxyAttributionType") ?? "auto" {
        case "clash": type = .clash
        case "surge": type = .surge
        case "off": type = .off
        default: type = .auto
        }
        return Config(
            enabled: enabled,
            type: type,
            baseURL: d.string(forKey: "proxyAttributionBaseURL") ?? "",
            secret: d.string(forKey: "proxyAttributionSecret") ?? ""
        )
    }

    private func reset() {
        previousConnections.removeAll(keepingCapacity: true)
        stateLock.lock()
        pendingCredits = [:]
        proxyPid = nil
        stateLock.unlock()
    }

    private func takeCreditsSnapshot() -> (credits: [Int: (inBytes: Int, outBytes: Int)], proxyPid: Int?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let credits = pendingCredits
        pendingCredits = [:]
        return (credits, proxyPid)
    }

    private func pidNamesSnapshot() -> [Int: String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pidNameCache
    }

    private func emitStatus(_ newStatus: ProxyStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status != newStatus else { return }
            self.status = newStatus
        }
    }
}
