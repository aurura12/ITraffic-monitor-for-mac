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
//        Clash Verge: Unix socket /tmp/verge/verge-mihomo.sock
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
import OSLog
import Combine
import AppKit

/// Use the proxy row as a safety cap when it is available. The proxy row is
/// not a prerequisite: nettop can omit a proxy process for an individual
/// frame even while the API and the app's local socket prove the traffic.
func capProxyCredit(requested: Int, observedByNettop: Int, proxyVisible: Bool) -> Int {
    guard requested > 0, proxyVisible else { return 0 }
    return min(requested, observedByNettop)
}

func proxyDisplayName(rawName: String, isClashVerge: Bool) -> String {
    isClashVerge ? "Clash Verge" : rawName
}

func attributedPID(previousPID: Int, resolvedPID: Int) -> Int {
    previousPID > 0 ? previousPID : resolvedPID
}

func nonNegativeProxyDelta(current: Int64, previous: Int64) -> Int64 {
    max(0, current - previous)
}

func proxyCreditPIDs(inBytes: [Int: Int], outBytes: [Int: Int]) -> Set<Int> {
    Set(inBytes.keys).union(outBytes.keys)
}

func proxyEntityMatches(pid: Int, name: String, proxyPIDs: Set<Int>, isClashVerge: Bool) -> Bool {
    proxyPIDs.contains(pid) ||
    (isClashVerge && canonicalProcessDisplayName(name) == "Clash Verge")
}

func accumulateProxyCredits(
    _ existing: inout [Int: (inBytes: Int, outBytes: Int)],
    _ additions: [Int: (inBytes: Int, outBytes: Int)]
) {
    for (pid, credit) in additions {
        var current = existing[pid] ?? (inBytes: 0, outBytes: 0)
        current.inBytes += credit.inBytes
        current.outBytes += credit.outBytes
        existing[pid] = current
    }
}

/// Custom proxy endpoints are only allowed on the local machine. This keeps
/// proxy credentials from being sent to an accidental or hostile remote URL.
func isAllowedProxyAPIURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.user == nil,
          let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

struct UnixSocketCurlResponse: Equatable {
    let statusCode: Int
    let body: String
}

func parseUnixSocketCurlOutput(_ output: String) -> UnixSocketCurlResponse? {
    let marker = "__ITRAFFIC_STATUS__:"
    guard let markerRange = output.range(of: marker, options: .backwards),
          let statusLine = output[markerRange.upperBound...]
            .split(whereSeparator: { $0.isNewline })
            .first,
          let statusCode = Int(statusLine.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    let body = String(output[..<markerRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return UnixSocketCurlResponse(statusCode: statusCode, body: body)
}

enum ProxyStatus: Equatable {
    case disabled
    case detected(name: String)
    case notDetected
    case secretRequired
}

enum ProxyDiagnostic: Equatable {
    case idle
    case detected(name: String, endpoint: String, connectionCount: Int, mappedConnectionCount: Int, proxyPID: Int?)
    case waitingForProxyRow(name: String, endpoint: String, connectionCount: Int, mappedConnectionCount: Int, proxyPID: Int?)
    case apiUnavailable(endpoint: String)
    case authRequired(endpoint: String)
    case notDetected
}

func proxyDiagnosticSummary(_ diagnostic: ProxyDiagnostic) -> String {
    switch diagnostic {
    case .idle:
        return "idle"
    case let .detected(name, endpoint, connectionCount, mappedConnectionCount, proxyPID):
        let pidText = proxyPID.map(String.init) ?? "nil"
        return "detected \(name) endpoint=\(endpoint) connections=\(connectionCount) mapped=\(mappedConnectionCount) proxyPID=\(pidText)"
    case let .waitingForProxyRow(name, endpoint, connectionCount, mappedConnectionCount, proxyPID):
        let pidText = proxyPID.map(String.init) ?? "nil"
        return "proxy row missing \(name) endpoint=\(endpoint) connections=\(connectionCount) mapped=\(mappedConnectionCount) proxyPID=\(pidText)"
    case let .apiUnavailable(endpoint):
        return "API unavailable endpoint=\(endpoint)"
    case let .authRequired(endpoint):
        return "API authentication required endpoint=\(endpoint)"
    case .notDetected:
        return "proxy not detected"
    }
}

enum ProxyFetchOutcome: Equatable {
    case success(connectionCount: Int)
    case transportFailure
    case authRequired
    case httpFailure(statusCode: Int)
    case invalidResponse
}

func proxyFetchOutcome(statusCode: Int?, hasBody: Bool, connectionCount: Int) -> ProxyFetchOutcome {
    guard let statusCode else { return .transportFailure }
    if statusCode == 401 || statusCode == 403 { return .authRequired }
    guard statusCode == 200 else { return .httpFailure(statusCode: statusCode) }
    guard hasBody else { return .invalidResponse }
    return .success(connectionCount: connectionCount)
}

func proxyEndpointLabel(_ endpoint: String) -> String {
    endpoint.hasPrefix("/") ? "unix:" + endpoint : endpoint
}

struct ProxyConfigEntry: Equatable {
    let key: String
    let value: String
}

func parseProxyConfigLine(_ line: String) -> ProxyConfigEntry? {
    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    if value.count >= 2,
       ((value.first == "'" && value.last == "'") || (value.first == "\"" && value.last == "\"")) {
        value.removeFirst()
        value.removeLast()
    }
    return ProxyConfigEntry(key: key, value: value)
}

/// Normalized proxy connection: `sourcePort` is the client app's local port.
private struct ProxyConnection {
    let id: String
    let sourcePort: Int
    let upload: Int64
    let download: Int64
    let process: String?
    let processPath: String?
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

    private let logger = Logger(subsystem: "com.foamzou.ITrafficMonitorForMac", category: "ProxyAttributor")

    @Published private(set) var status: ProxyStatus = .disabled
    @Published private(set) var diagnostic: ProxyDiagnostic = .idle

    // MARK: - State shared with the nettop runner queue (locked)

    private let stateLock = NSLock()
    /// Bytes to credit back to apps (keyed by pid) from the most recent tick.
    private var pendingCredits: [Int: (inBytes: Int, outBytes: Int)] = [:]
    /// The proxy process pid (owns the external-controller listening socket).
    private var proxyPid: Int?
    private var proxyPIDs: Set<Int> = []
    /// True when proxyPid belongs to Clash Verge's verge-mihomo core.
    private var isClashVergeProxy = false
    /// pid -> process name from lsof, used as a fallback name for new entities.
    private var pidNameCache: [Int: String] = [:]
    private var lastProxyName = ""
    private var lastProxyEndpoint = ""
    private var lastConnectionCount = 0
    private var lastMappedConnectionCount = 0
    private var lastProxyRowVisible: Bool?

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
        let unixSocket: String?
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
        guard snapshot.proxyPid != nil else {
            return raw
        }

        // Locate the proxy entity in this frame. It may be absent if the
        // frame window and the attributor tick are out of phase; that must
        // not hide app traffic already confirmed by the proxy API.
        var proxyIndex: Int?
        for (i, e) in raw.enumerated()
        where proxyEntityMatches(pid: e.pid, name: e.name, proxyPIDs: snapshot.proxyPIDs, isClashVerge: snapshot.isClashVergeProxy) {
            proxyIndex = i
            break
        }
        let proxyVisible = proxyIndex != nil
        let proxyIn = proxyIndex.map { raw[$0].inBytes } ?? 0
        let proxyOut = proxyIndex.map { raw[$0].outBytes } ?? 0

        if noteProxyRowVisibility(proxyVisible), let detection = detectionSnapshot() {
            let diagnostic: ProxyDiagnostic = proxyVisible
                ? .detected(
                    name: detection.name,
                    endpoint: detection.endpoint,
                    connectionCount: detection.connectionCount,
                    mappedConnectionCount: detection.mappedConnectionCount,
                    proxyPID: detection.proxyPID
                )
                : .waitingForProxyRow(
                    name: detection.name,
                    endpoint: detection.endpoint,
                    connectionCount: detection.connectionCount,
                    mappedConnectionCount: detection.mappedConnectionCount,
                    proxyPID: detection.proxyPID
                )
            logger.info("proxy row visibility=\(proxyVisible, privacy: .public) \(proxyDiagnosticSummary(diagnostic), privacy: .public)")
            emitDiagnostic(diagnostic)
        }
        guard let proxyIndex else {
            return raw
        }

        let totalIn = snapshot.credits.values.reduce(0) { $0 + $1.inBytes }
        let totalOut = snapshot.credits.values.reduce(0) { $0 + $1.outBytes }

        // Direction-level cap: when the proxy entity is visible in the same
        // frame, apps are never credited more than the proxy actually carried
        // (guards against API-payload vs wire-bytes drift). When it is absent,
        // use the API delta directly so a nettop phase gap cannot erase app
        // traffic that has already been identified by source port.
        let usableIn = capProxyCredit(requested: totalIn, observedByNettop: proxyIn, proxyVisible: proxyVisible)
        let usableOut = capProxyCredit(requested: totalOut, observedByNettop: proxyOut, proxyVisible: proxyVisible)
        let scaleIn = totalIn > 0 ? Double(usableIn) / Double(totalIn) : 1.0
        let scaleOut = totalOut > 0 ? Double(usableOut) / Double(totalOut) : 1.0

        var creditedIn: [Int: Int] = [:]
        var creditedOut: [Int: Int] = [:]
        for (pid, c) in snapshot.credits where !snapshot.proxyPIDs.contains(pid) {
            let scaledIn = Int(Double(c.inBytes) * scaleIn)
            let scaledOut = Int(Double(c.outBytes) * scaleOut)
            if scaledIn > 0 || scaledOut > 0 {
                creditedIn[pid] = scaledIn
                creditedOut[pid] = scaledOut
            }
        }
        let sumIn = creditedIn.values.reduce(0, +)
        let sumOut = creditedOut.values.reduce(0, +)
        let consumedCredits = proxyCreditPIDs(inBytes: creditedIn, outBytes: creditedOut).reduce(into: [Int: (inBytes: Int, outBytes: Int)]()) { result, pid in
            result[pid] = (inBytes: creditedIn[pid] ?? 0, outBytes: creditedOut[pid] ?? 0)
        }
        consumeProxyCredits(consumedCredits)
        var result: [ProcessEntity] = []
        var existingByPid: [Int: Int] = [:]

        for (i, e) in raw.enumerated() {
            var entity = e
            if proxyEntityMatches(pid: e.pid, name: e.name, proxyPIDs: snapshot.proxyPIDs, isClashVerge: snapshot.isClashVergeProxy) {
                // Normalize the raw nettop name even when this frame does
                // not contain a proxy row at proxyIndex. Otherwise the live
                // list can show both "Clash Verge" and "verge-mihomo" while
                // the database correctly uses one canonical key.
                entity.name = proxyDisplayName(
                    rawName: entity.name,
                    isClashVerge: snapshot.isClashVergeProxy
                )
            }
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
            logger.info("proxy detected name=\(c.name, privacy: .public) connections=\(connections.count) proxyPIDs=\(self.proxyPIDs.sorted().map(String.init).joined(separator: ","), privacy: .public)")
            emitStatus(.detected(name: c.name))
        case .secretRequired:
            logger.error("proxy controller requires secret")
            reset()
            emitStatus(.secretRequired)
            let endpoint = candidates.map { proxyEndpointLabel($0.unixSocket ?? $0.baseURL) }.joined(separator: ",")
            logger.error("proxy API authentication required endpoints=\(endpoint, privacy: .public)")
            emitDiagnostic(.authRequired(endpoint: endpoint))
        case .notFound:
            logger.debug("proxy controller not found")
            reset()
            emitStatus(.notDetected)
            let endpoint = candidates.map { proxyEndpointLabel($0.unixSocket ?? $0.baseURL) }.joined(separator: ",")
            logger.info("proxy API unavailable endpoints=\(endpoint, privacy: .public)")
            emitDiagnostic(.apiUnavailable(endpoint: endpoint))
        }
    }

    private func applyDetection(candidate: Candidate, connections: [ProxyConnection]) {
        let portMap = socketPortMap()
        let proxyPIDs = resolveProxyPIDs(candidate: candidate)
        let proxyPid = proxyPIDs.sorted().first
        let prev = previousConnections

        var credits: [Int: (inBytes: Int, outBytes: Int)] = [:]
        var newPrevious: [String: TrackedConnection] = [:]
        var mappedConnectionCount = 0

        for conn in connections {
            let resolvedPID = portMap.ports[conn.sourcePort]
                ?? resolveProcessPID(name: conn.process, path: conn.processPath)
                ?? 0
            let pid = attributedPID(
                previousPID: prev[conn.id]?.pid ?? 0,
                resolvedPID: resolvedPID
            )
            if pid > 0 {
                mappedConnectionCount += 1
            }
            newPrevious[conn.id] = TrackedConnection(
                pid: pid,
                sourcePort: conn.sourcePort,
                uploadTotal: conn.upload,
                downloadTotal: conn.download
            )
            guard let prevConn = prev[conn.id] else { continue }
            let dIn = nonNegativeProxyDelta(current: conn.download, previous: prevConn.downloadTotal)
            let dOut = nonNegativeProxyDelta(current: conn.upload, previous: prevConn.uploadTotal)
            if (dIn > 0 || dOut > 0), prevConn.pid > 0, !proxyPIDs.contains(prevConn.pid) {
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
        accumulateProxyCredits(&pendingCredits, credits)
        self.proxyPid = proxyPid
        self.proxyPIDs = proxyPIDs
        isClashVergeProxy = candidate.name == "Clash Verge"
        pidNameCache.merge(portMap.names) { _, new in new }
        lastProxyName = candidate.name
        lastProxyEndpoint = proxyEndpointLabel(candidate.unixSocket ?? candidate.baseURL)
        lastConnectionCount = connections.count
        lastMappedConnectionCount = mappedConnectionCount
        lastProxyRowVisible = nil
        stateLock.unlock()
        emitDiagnostic(.detected(
            name: candidate.name,
            endpoint: proxyEndpointLabel(candidate.unixSocket ?? candidate.baseURL),
            connectionCount: connections.count,
            mappedConnectionCount: mappedConnectionCount,
            proxyPID: proxyPid
        ))
        if !credits.isEmpty {
            let totalIn = credits.values.reduce(0) { $0 + $1.inBytes }
            let totalOut = credits.values.reduce(0) { $0 + $1.outBytes }
            logger.info("proxy credits pids=\(credits.keys.sorted().map(String.init).joined(separator: ","), privacy: .public) in=\(totalIn) out=\(totalOut) proxyPid=\(proxyPid ?? 0)")
        }
    }

    // MARK: - Detection / fetch

    private func candidates(for cfg: Config) -> [Candidate] {
        let base = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            guard isAllowedProxyAPIURL(base) else { return [] }
            // Custom base URL overrides the built-in defaults.
            let port = URL(string: base)?.port ?? (cfg.type == .surge ? 6171 : 9090)
            let path = cfg.type == .surge ? "/v1/connections" : "/connections"
            let name = cfg.type == .surge ? "Surge" : "Clash"
            return [Candidate(baseURL: base, path: path, port: port, name: name, unixSocket: nil)]
        }
        switch cfg.type {
        case .clash:
            // Clash (9090) and Clash Verge / Mihomo (9097) use the same
            // /connections shape; probe both so either is detected in auto.
            return clashVergeCandidates() + [
                Candidate(baseURL: "http://127.0.0.1:9090", path: "/connections", port: 9090, name: "Clash", unixSocket: nil),
                Candidate(baseURL: "http://127.0.0.1:9097", path: "/connections", port: 9097, name: "Clash Verge", unixSocket: nil),
            ]
        case .surge:
            return [Candidate(baseURL: "http://127.0.0.1:6171", path: "/v1/connections", port: 6171, name: "Surge", unixSocket: nil)]
        case .auto:
            return clashVergeCandidates() + [
                Candidate(baseURL: "http://127.0.0.1:9090", path: "/connections", port: 9090, name: "Clash", unixSocket: nil),
                Candidate(baseURL: "http://127.0.0.1:9097", path: "/connections", port: 9097, name: "Clash Verge", unixSocket: nil),
                Candidate(baseURL: "http://127.0.0.1:6171", path: "/v1/connections", port: 6171, name: "Surge", unixSocket: nil),
            ]
        case .off:
            return []
        }
    }

    private func clashVergeCandidates() -> [Candidate] {
        let values = clashVergeConfigValues()
        let socket = values["external-controller-unix"] ?? clashVergeSocketPath()
        var result = [Candidate(
            baseURL: "",
            path: "/connections",
            port: 9097,
            name: "Clash Verge",
            unixSocket: socket
        )]
        if let controller = values["external-controller"],
           let url = URL(string: "http://" + controller),
           let host = url.host,
           host == "127.0.0.1" || host == "localhost" || host == "::1" {
            result.append(Candidate(
                baseURL: "http://" + controller,
                path: "/connections",
                port: url.port ?? 9097,
                name: "Clash Verge",
                unixSocket: nil
            ))
        }
        return result
    }

    private func clashVergeConfigValues() -> [String: String] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { parseProxyConfigLine(String($0)) }
            .reduce(into: [:]) { $0[$1.key] = $1.value }
    }

    private func clashVergeSocketPath() -> String {
        let defaultPath = "/tmp/verge/verge-mihomo.sock"
        let pidURL = URL(fileURLWithPath: "/tmp/verge/clash-verge-service.core.json")
        guard let data = try? Data(contentsOf: pidURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ipcPath = object["ipc_path"] as? String,
              ipcPath.hasPrefix("/") else {
            return defaultPath
        }
        return ipcPath
    }

    private func tryDetect(_ candidates: [Candidate], secret: String) -> DetectResult {
        var sawAuthRequired = false
        for c in candidates {
            switch fetch(c, secret: secret) {
            case .authRequired:
                sawAuthRequired = true
            case .ok(let connections):
                // A valid empty table still proves that the proxy API is alive.
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

    private func fetch(_ candidate: Candidate, secret: String) -> FetchResult {
        if let unixSocket = candidate.unixSocket {
            return fetchUnixSocket(unixSocket, path: candidate.path, secret: secret)
        }
        return fetchHTTP(candidate.baseURL + candidate.path, secret: secret)
    }

    private func fetchHTTP(_ urlString: String, secret: String) -> FetchResult {
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
        guard statusCode == 200, let data, let conns = decodeConnections(data) else {
            return .failed
        }
        return .ok(conns)
    }

    private func fetchUnixSocket(_ socketPath: String, path: String, secret: String) -> FetchResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var args = [
            "-sS", "--max-time", "2",
            "--unix-socket", socketPath,
            "-H", "Accept: application/json"
        ]
        if !secret.isEmpty {
            args += ["-H", "Authorization: Bearer \(secret)"]
        }
        args += ["-w", "\\n__ITRAFFIC_STATUS__:%{http_code}", "http://localhost\(path)"]
        process.arguments = args

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8),
                  let response = parseUnixSocketCurlOutput(text) else {
                return .failed
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                return .authRequired
            }
            guard response.statusCode == 200,
                  let body = response.body.data(using: .utf8),
                  let conns = decodeConnections(body) else {
                return .failed
            }
            return .ok(conns)
        } catch {
            return .failed
        }
    }

    /// Decodes both the Clash shape (metadata.sourcePort / upload / download)
    /// and the Surge shape (source.port / bytes.up / bytes.down).
    private func decodeConnections(_ data: Data) -> [ProxyConnection]? {
        struct Raw: Decodable {
            struct C: Decodable {
                struct Metadata: Decodable {
                    let sourcePort: String?
                    let process: String?
                    let processPath: String?
                }
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
                download: Int64(c.download ?? c.bytes?.down ?? 0),
                process: c.metadata?.process,
                processPath: c.metadata?.processPath
            ))
        }
        return out
    }

    /// Resolve Mihomo's optional process metadata to a currently running PID.
    /// TUN connections can only be attributed this way; their virtual source
    /// port does not belong to the originating application's socket table.
    private func resolveProcessPID(name: String?, path: String?) -> Int? {
        let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(normalizedPath?.isEmpty ?? true) || !(normalizedName?.isEmpty ?? true) else {
            return nil
        }

        for app in NSWorkspace.shared.runningApplications {
            if let normalizedPath,
               !normalizedPath.isEmpty,
               app.executableURL?.path == normalizedPath {
                return Int(app.processIdentifier)
            }
            if let normalizedName,
               !normalizedName.isEmpty,
               app.localizedName?.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame {
                return Int(app.processIdentifier)
            }
        }
        return nil
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

    /// PID of the process serving the proxy controller.
    private func resolveProxyPIDs(candidate: Candidate) -> Set<Int> {
        var pids = Set<Int>()
        if let unixSocket = candidate.unixSocket {
            if let output = runLsof(["-nP", "-U", unixSocket]),
               let pid = firstPID(in: output) {
                pids.insert(pid)
            }

            // Clash Verge's privileged core keeps its PID next to the socket.
            // This fallback handles the case where lsof cannot inspect the
            // root-owned core process from the app context.
            let socketURL = URL(fileURLWithPath: unixSocket)
            let pidURL = socketURL.deletingLastPathComponent()
                .appendingPathComponent("clash-verge-service.core.json")
            if let data = try? Data(contentsOf: pidURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = object["pid"] as? Int {
                pids.insert(pid)
            }
        }
        if let pid = resolveProxyPid(port: candidate.port) {
            pids.insert(pid)
        }
        return pids
    }

    private func resolveProxyPid(port: Int) -> Int? {
        guard let output = runLsof(["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]) else { return nil }
        return firstPID(in: output)
    }

    private func firstPID(in output: String) -> Int? {
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
        let configSecret = d.string(forKey: "proxyAttributionSecret") ?? ""
        let autoSecret = (type == .auto || type == .clash) ? clashVergeConfigValues()["secret"] : nil
        return Config(
            enabled: enabled,
            type: type,
            baseURL: d.string(forKey: "proxyAttributionBaseURL") ?? "",
            secret: configSecret.isEmpty ? (autoSecret ?? "") : configSecret
        )
    }

    private func reset() {
        previousConnections.removeAll(keepingCapacity: true)
        stateLock.lock()
        pendingCredits = [:]
        proxyPid = nil
        proxyPIDs = []
        isClashVergeProxy = false
        stateLock.unlock()
        emitDiagnostic(.notDetected)
    }

    private func takeCreditsSnapshot() -> (
        credits: [Int: (inBytes: Int, outBytes: Int)],
        proxyPid: Int?,
        proxyPIDs: Set<Int>,
        isClashVergeProxy: Bool
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (pendingCredits, proxyPid, proxyPIDs, isClashVergeProxy)
    }

    private func detectionSnapshot() -> (name: String, endpoint: String, connectionCount: Int, mappedConnectionCount: Int, proxyPID: Int?)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let proxyPID = self.proxyPid else { return nil }
        return (lastProxyName, lastProxyEndpoint, lastConnectionCount, lastMappedConnectionCount, proxyPID)
    }

    private func noteProxyRowVisibility(_ visible: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lastProxyRowVisible != visible else { return false }
        lastProxyRowVisible = visible
        return true
    }

    private func consumeProxyCredits(_ consumed: [Int: (inBytes: Int, outBytes: Int)]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        for (pid, credit) in consumed {
            guard var pending = pendingCredits[pid] else { continue }
            pending.inBytes = max(0, pending.inBytes - credit.inBytes)
            pending.outBytes = max(0, pending.outBytes - credit.outBytes)
            if pending.inBytes == 0 && pending.outBytes == 0 {
                pendingCredits.removeValue(forKey: pid)
            } else {
                pendingCredits[pid] = pending
            }
        }
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

    private func emitDiagnostic(_ newDiagnostic: ProxyDiagnostic) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.diagnostic != newDiagnostic else { return }
            self.diagnostic = newDiagnostic
        }
    }
}
