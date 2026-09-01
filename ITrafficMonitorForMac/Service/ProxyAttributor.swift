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

struct PendingProxyCredit: Equatable {
    let timestamp: Int64
    let pid: Int
    var inBytes: Int
    var outBytes: Int
}

struct PendingCreditConsumption {
    let credited: [Int: (inBytes: Int, outBytes: Int)]
    let remaining: [PendingProxyCredit]
}

/// The result of settling one nettop frame. `credited` describes only bytes
/// that were moved out of the raw Clash row in this frame. Declarations that
/// could not be paid by this frame are returned for diagnostics, but must be
/// discarded by the caller at finalization; they are never a debt.
struct ConservativeProxySettlement {
    let entities: [ProcessEntity]
    let credited: [Int: (inBytes: Int, outBytes: Int)]
    let droppedDeclarations: [PendingProxyCredit]
}

/// Re-attribute a single raw nettop frame without creating bytes.
///
/// The raw proxy row is the only budget. API declarations can move at most
/// that row's download/upload bytes, independently by direction. If there is
/// no matching proxy row, no declaration is consumed and all bytes remain on
/// their original rows. There is intentionally no historical window budget,
/// foreground fallback, or cross-frame debt in this function.
func settleProxyWindow(
    raw: [ProcessEntity],
    proxyPIDs: Set<Int>,
    isClashVerge: Bool,
    declarations: [PendingProxyCredit],
    pidNames: [Int: String]
) -> ConservativeProxySettlement {
    var proxyIndex: Int?
    var proxyBytes = -1
    for (index, entity) in raw.enumerated()
    where proxyEntityMatches(pid: entity.pid, name: entity.name, proxyPIDs: proxyPIDs, isClashVerge: isClashVerge) {
        let bytes = max(0, entity.inBytes) + max(0, entity.outBytes)
        if bytes > proxyBytes {
            proxyBytes = bytes
            proxyIndex = index
        }
    }

    guard let proxyIndex else {
        return ConservativeProxySettlement(
            entities: raw,
            credited: [:],
            droppedDeclarations: declarations
        )
    }

    let proxy = raw[proxyIndex]
    let consumable = declarations.filter { $0.pid > 0 && !proxyPIDs.contains($0.pid) }
    let consumption = consumePendingProxyCredits(
        consumable,
        availableIn: max(0, proxy.inBytes),
        availableOut: max(0, proxy.outBytes)
    )
    let creditedIn = consumption.credited.mapValues(\.inBytes)
    let creditedOut = consumption.credited.mapValues(\.outBytes)

    var result: [ProcessEntity] = []
    var creditedExistingPIDs = Set<Int>()
    for (index, entity) in raw.enumerated() {
        var updated = entity
        if proxyEntityMatches(pid: entity.pid, name: entity.name, proxyPIDs: proxyPIDs, isClashVerge: isClashVerge) {
            updated.name = proxyDisplayName(rawName: entity.name, isClashVerge: isClashVerge)
        }
        if index == proxyIndex {
            updated.inBytes = max(0, entity.inBytes) - creditedIn.values.reduce(0, +)
            updated.outBytes = max(0, entity.outBytes) - creditedOut.values.reduce(0, +)
        } else if (creditedIn[entity.pid] != nil || creditedOut[entity.pid] != nil),
                  !creditedExistingPIDs.contains(entity.pid) {
            updated.inBytes = max(0, entity.inBytes) + (creditedIn[entity.pid] ?? 0)
            updated.outBytes = max(0, entity.outBytes) + (creditedOut[entity.pid] ?? 0)
            creditedExistingPIDs.insert(entity.pid)
        }
        result.append(updated)
    }

    for pid in proxyCreditPIDs(inBytes: creditedIn, outBytes: creditedOut) where !creditedExistingPIDs.contains(pid) {
        let inBytes = creditedIn[pid] ?? 0
        let outBytes = creditedOut[pid] ?? 0
        let fallback = pidNames[pid] ?? "\(pid)"
        let name = getAppInfo(pid: pid, name: fallback)?.name ?? fallback
        result.append(ProcessEntity(pid: pid, name: name, inBytes: inBytes, outBytes: outBytes))
    }

    let dropped = consumption.remaining + declarations.filter { $0.pid <= 0 || proxyPIDs.contains($0.pid) }
    return ConservativeProxySettlement(
        entities: result,
        credited: consumption.credited,
        droppedDeclarations: dropped
    )
}

func consumePendingProxyCredits(
    _ credits: [PendingProxyCredit],
    availableIn: Int,
    availableOut: Int
) -> PendingCreditConsumption {
    var availableIn = max(0, availableIn)
    var availableOut = max(0, availableOut)
    var credited: [Int: (inBytes: Int, outBytes: Int)] = [:]
    var remaining: [PendingProxyCredit] = []

    for var credit in credits {
        let inBytes = min(credit.inBytes, availableIn)
        let outBytes = min(credit.outBytes, availableOut)
        if inBytes > 0 || outBytes > 0 {
            var total = credited[credit.pid] ?? (inBytes: 0, outBytes: 0)
            total.inBytes += inBytes
            total.outBytes += outBytes
            credited[credit.pid] = total
            availableIn -= inBytes
            availableOut -= outBytes
            credit.inBytes -= inBytes
            credit.outBytes -= outBytes
        }
        if credit.inBytes > 0 || credit.outBytes > 0 {
            remaining.append(credit)
        }
    }
    return PendingCreditConsumption(credited: credited, remaining: remaining)
}

/// Result of observing one frame's proxy-row visibility.
struct ProxyRowVisibilityUpdate {
    /// True when a genuine transition was recorded and `diagnostic` carries
    /// the data needed to emit the visibility-change diagnostic.
    let changed: Bool
    /// The visibility value to persist when `changed` is true.
    let newLastVisible: Bool?
    let diagnostic: (name: String, endpoint: String, connectionCount: Int, mappedConnectionCount: Int, proxyPID: Int?)?
}

/// Pure state transition for the proxy-row visibility diagnostic.
///
/// When detection is inactive, the transition is NOT recorded (returns
/// `changed == false` and keeps `lastProxyRowVisible`), so the caller retries
/// on the next frame. Without this, a frame that races a transient `reset()`
/// would consume the only visibility change while `detectionSnapshot` is
/// momentarily unavailable, and the diagnostic would never be emitted again.
func recordingProxyRowVisibility(
    visible: Bool,
    proxyDetected: Bool,
    lastProxyRowVisible: Bool?,
    diagnostic: (name: String, endpoint: String, connectionCount: Int, mappedConnectionCount: Int, proxyPID: Int?)?
) -> ProxyRowVisibilityUpdate {
    guard proxyDetected else {
        return ProxyRowVisibilityUpdate(changed: false, newLastVisible: lastProxyRowVisible, diagnostic: nil)
    }
    guard lastProxyRowVisible != visible else {
        return ProxyRowVisibilityUpdate(changed: false, newLastVisible: lastProxyRowVisible, diagnostic: nil)
    }
    return ProxyRowVisibilityUpdate(changed: true, newLastVisible: visible, diagnostic: diagnostic)
}

func proxyCreditConsumptionSummary(
    creditedIn: Int,
    creditedOut: Int,
    pendingIn: Int,
    pendingOut: Int,
    proxyIn: Int,
    proxyOut: Int
) -> String {
    "proxy credits consumed in=\(creditedIn) out=\(creditedOut) pendingIn=\(pendingIn) pendingOut=\(pendingOut) proxyIn=\(proxyIn) proxyOut=\(proxyOut)"
}

func retainingNewestDiagnosticLogBytes(_ data: Data, maximumBytes: Int) -> Data {
    guard data.count > maximumBytes else { return data }
    return data.suffix(maximumBytes)
}

final class DiagnosticLogStore: ObservableObject {
    static let shared = DiagnosticLogStore()

    let logURL: URL
    private let queue = DispatchQueue(label: "diagnostic-log", qos: .utility)
    // 16 MB: per-pid credit lines during active traffic are the core debugging
    // data and accumulate faster than the event-only lines.
    private let maximumBytes = 16 * 1024 * 1024

    private init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ITraffic", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("proxy-diagnostics.log")
    }

    func append(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async { [logURL, maximumBytes] in
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
            // O(1) size check via stat; the full read+rewrite only runs at the
            // high-water mark and trims to half the cap, so it is amortized
            // over ~8 MB of subsequent appends instead of running on every
            // line once the log is full.
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard size > maximumBytes, let current = try? Data(contentsOf: logURL) else { return }
            let trimmed = retainingNewestDiagnosticLogBytes(current, maximumBytes: maximumBytes / 2)
            try? trimmed.write(to: logURL, options: .atomic)
        }
    }

    func clear() {
        queue.async { [logURL] in try? FileManager.default.removeItem(at: logURL) }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    func export(to destination: URL) throws {
        try queue.sync {
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            try data.write(to: destination, options: .atomic)
        }
    }
}

enum SocketProtocol: Hashable, CaseIterable {
    case tcp
    case udp

    init?(rawValue: String?) {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tcp": self = .tcp
        case "udp": self = .udp
        default: return nil
        }
    }
}

struct SocketKey: Hashable {
    let `protocol`: SocketProtocol
    let port: Int
}

struct SocketOwner: Equatable {
    let pid: Int
    let name: String
    let startTime: Int64?

    init(pid: Int, name: String, startTime: Int64? = nil) {
        self.pid = pid
        self.name = name
        self.startTime = startTime
    }
}

struct CachedSocketOwner: Equatable {
    let pid: Int
    let name: String
    let lastSeen: Int64
    let startTime: Int64?

    init(pid: Int, name: String, lastSeen: Int64, startTime: Int64? = nil) {
        self.pid = pid
        self.name = name
        self.lastSeen = lastSeen
        self.startTime = startTime
    }
}

func mergeSocketOwners(
    live: [SocketKey: SocketOwner],
    cached: [SocketKey: CachedSocketOwner],
    now: Int64,
    ttl: Int64,
    ownerIsCurrent: (CachedSocketOwner) -> Bool = { _ in true }
) -> [SocketKey: SocketOwner] {
    var result = live
    for (port, entry) in cached
    where result[port] == nil && now - entry.lastSeen <= ttl && ownerIsCurrent(entry) {
        result[port] = SocketOwner(pid: entry.pid, name: entry.name, startTime: entry.startTime)
    }
    return result
}

/// Resolve a proxy-reported source port to a process. When the proxy does not
/// report its transport, only a single TCP/UDP owner is safe to use; choosing
/// one from an ambiguous port would silently charge the wrong application.
func socketOwnerPID(
    sourcePort: Int,
    transport: SocketProtocol?,
    ports: [SocketKey: Int]
) -> Int? {
    if let transport {
        return ports[SocketKey(protocol: transport, port: sourcePort)]
    }

    let candidates = Set(SocketProtocol.allCases.compactMap {
        ports[SocketKey(protocol: $0, port: sourcePort)]
    })
    return candidates.count == 1 ? candidates.first : nil
}

/// A connection id is not sufficient as an identity forever. If a proxy
/// reuses an id for a different source endpoint, retaining the previous PID
/// would attribute the new connection to the old application.
func shouldReuseTrackedProxyPID(
    previousSourcePort: Int,
    previousTransport: SocketProtocol?,
    currentSourcePort: Int,
    currentTransport: SocketProtocol?
) -> Bool {
    previousSourcePort == currentSourcePort && previousTransport == currentTransport
}

func proxyMappingCoverage(_ diagnostic: ProxyDiagnostic) -> Double? {
    switch diagnostic {
    case let .detected(_, _, connectionCount, mappedConnectionCount, _),
         let .waitingForProxyRow(_, _, connectionCount, mappedConnectionCount, _):
        guard connectionCount > 0 else { return 1 }
        return min(1, max(0, Double(mappedConnectionCount) / Double(connectionCount)))
    case .idle, .apiUnavailable, .authRequired, .notDetected:
        return nil
    }
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
    let transport: SocketProtocol?
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
    let transport: SocketProtocol?
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
    private var pendingCredits: [PendingProxyCredit] = []
    /// True once the proxy controller responded. Redistribution keys off this
    /// flag rather than `proxyPid`: a resolved pid can be missing when the
    /// core runs as root (invisible to the app's lsof), while name matching
    /// still reliably identifies the proxy row.
    private var proxyDetected = false
    /// The proxy process pid (owns the external-controller listening socket).
    private var proxyPid: Int?
    private var proxyPIDs: Set<Int> = []
    private var sourcePortCache: [SocketKey: CachedSocketOwner] = [:]
    private let sourcePortCacheTTL: Int64 = 10
    /// True when proxyPid belongs to Clash Verge's verge-mihomo core.
    private var isClashVergeProxy = false
    /// pid -> process name from lsof, used as a fallback name for new entities.
    private var pidNameCache: [Int: String] = [:]
    /// Maps short-lived CLI process pids (node, npm, …) to the regular GUI
    /// application that hosts them (the terminal / IDE), so proxy traffic
    /// from terminal commands is shown under the app the user actually sees.
    /// Each entry records the pid's process start time so a recycled pid
    /// cannot inherit the previous process's host application.
    private struct GuiAncestorCacheEntry {
        let hostPID: Int
        let startTime: Int64?
    }
    private var guiAncestorCache: [Int: GuiAncestorCacheEntry] = [:]
    /// Last status label appended to the diagnostics log, so only genuine
    /// status transitions are recorded.
    private var lastLoggedStatus = ""
    /// Tick counter (2 s cadence); a state-snapshot heartbeat is appended every
    /// 30 ticks (~60 s) so silent gaps in the diagnostics log are visible.
    private var tickCount = 0
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
    /// Epoch seconds of the last successful connection poll. A gap larger
    /// than `staleGapSeconds` means the proxy API was unreachable for the
    /// intervening window; the then-computed deltas cover bytes that already
    /// landed on the proxy row in earlier frames and must not be credited.
    private var lastDetectionAt: Int64 = 0
    /// Deltas spanning a poll gap wider than this are considered stale
    /// (3 missed ticks) and are kept on the proxy row instead of credited.
    private let staleGapSeconds: Int64 = 7

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

    /// Called on the nettop runner queue. Re-distributes only the current
    /// frame's raw Clash bytes using declarations from the matching API poll.
    func attributedEntities(_ raw: [ProcessEntity]) -> [ProcessEntity] {
        let snapshot = takeCurrentWindowSnapshot()
        guard snapshot.proxyDetected else {
            return raw
        }

        let proxyVisible = raw.contains {
            proxyEntityMatches(
                pid: $0.pid,
                name: $0.name,
                proxyPIDs: snapshot.proxyPIDs,
                isClashVerge: snapshot.isClashVergeProxy
            )
        }

        let visibility = noteProxyRowVisibility(proxyVisible)
        if visibility.changed, let detection = visibility.diagnostic {
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
            DiagnosticLogStore.shared.append("proxy row visibility=\(proxyVisible) \(proxyDiagnosticSummary(diagnostic))")
            emitDiagnostic(diagnostic)
        }

        let outcome = settleProxyWindow(
            raw: raw,
            proxyPIDs: snapshot.proxyPIDs,
            isClashVerge: snapshot.isClashVergeProxy,
            declarations: snapshot.declarations,
            pidNames: pidNamesSnapshot(),
        )

        let sumIn = outcome.credited.values.reduce(0) { $0 + $1.inBytes }
        let sumOut = outcome.credited.values.reduce(0) { $0 + $1.outBytes }
        if sumIn > 0 || sumOut > 0 {
            logger.info("proxy frame settlement credited in=\(sumIn, privacy: .public) out=\(sumOut, privacy: .public)")
            DiagnosticLogStore.shared.append("proxy frame settlement credited in=\(sumIn) out=\(sumOut)")
        }
        if !outcome.droppedDeclarations.isEmpty {
            let droppedIn = outcome.droppedDeclarations.reduce(0) { $0 + $1.inBytes }
            let droppedOut = outcome.droppedDeclarations.reduce(0) { $0 + $1.outBytes }
            logger.info("proxy declarations left unmatched in=\(droppedIn, privacy: .public) out=\(droppedOut, privacy: .public)")
            DiagnosticLogStore.shared.append("proxy declarations left unmatched in=\(droppedIn) out=\(droppedOut)")
        }
        return outcome.entities
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
            applyDetection(
                candidate: c,
                connections: connections
            )
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
            // Transient API failures (timeouts under load) must not discard
            // tracked connection totals: a full reset() would make the next
            // successful tick re-credit every surviving connection's
            // session-cumulative bytes as a "first observation", monopolizing
            // the recovery frame's proxy-row budget and starving other apps'
            // declarations exactly when the system is loaded (the condition
            // that caused the timeout). Suspend attribution but keep the
            // per-connection totals so recovery stays incremental.
            suspendAttribution()
            emitStatus(.notDetected)
            let endpoint = candidates.map { proxyEndpointLabel($0.unixSocket ?? $0.baseURL) }.joined(separator: ",")
            logger.info("proxy API unavailable endpoints=\(endpoint, privacy: .public)")
            emitDiagnostic(.apiUnavailable(endpoint: endpoint))
        }
    }

    private func applyDetection(
        candidate: Candidate,
        connections: [ProxyConnection]
    ) {
        let socketSnapshot = socketPortMap(for: connections)
        let now = Int64(Date().timeIntervalSince1970)
        let owners = mergeSocketOwners(
            live: socketSnapshot.owners,
            cached: sourcePortCache,
            now: now,
            ttl: sourcePortCacheTTL,
            ownerIsCurrent: { entry in
                guard let expectedStartTime = entry.startTime else { return true }
                return processStartTime(of: entry.pid) == expectedStartTime
            }
        )
        let liveCache = socketSnapshot.owners.mapValues {
            CachedSocketOwner(
                pid: $0.pid,
                name: $0.name,
                lastSeen: now,
                startTime: $0.startTime ?? processStartTime(of: $0.pid)
            )
        }
        sourcePortCache = sourcePortCache.filter {
            socketSnapshot.owners[$0.key] == nil && now - $0.value.lastSeen <= sourcePortCacheTTL
        }
        sourcePortCache.merge(liveCache) { _, new in new }
        let ownerNames = owners.values.reduce(into: [Int: String]()) { result, owner in
            result[owner.pid] = owner.name
        }
        let portMap = (
            ports: owners.mapValues { $0.pid },
            names: socketSnapshot.names.merging(ownerNames) { _, new in new }
        )
        let proxyPIDs = resolveProxyPIDs(candidate: candidate)
        let proxyPid = proxyPIDs.sorted().first
        let prev = previousConnections
        // After a long poll gap (proxy API unreachable) the deltas computed
        // below would cover the whole outage window — bytes that already sat
        // on the proxy row in earlier frames. Crediting them would distort
        // this frame's attribution, so they stay on the proxy row instead.
        let staleGap = lastDetectionAt > 0 && now - lastDetectionAt > staleGapSeconds

        var credits: [Int: (inBytes: Int, outBytes: Int)] = [:]
        var newPrevious: [String: TrackedConnection] = [:]
        var mappedConnectionCount = 0
        var unmappedIn = 0
        var unmappedOut = 0
        // Source ports that could not be mapped to a pid this tick; the first
        // few are logged so repeated patterns (e.g. always the same ephemeral
        // port range) are visible.
        var unmappedPorts: [Int] = []
        for conn in connections {
            let resolvedPID = socketOwnerPID(
                sourcePort: conn.sourcePort,
                transport: conn.transport,
                ports: portMap.ports
            )
                ?? resolveProcessPID(name: conn.process, path: conn.processPath)
                ?? 0
            let previous = prev[conn.id]
            let previousPID = previous.flatMap {
                shouldReuseTrackedProxyPID(
                    previousSourcePort: $0.sourcePort,
                    previousTransport: $0.transport,
                    currentSourcePort: conn.sourcePort,
                    currentTransport: conn.transport
                ) ? $0.pid : nil
            } ?? 0
            let pid = attributedPID(
                previousPID: previousPID,
                resolvedPID: resolvedPID
            )
            // Terminal commands (node, npm, curl, …) are short-lived CLI
            // processes; merge their proxy bytes into the terminal / IDE that
            // hosts them so the traffic shows under the app the user sees.
            // The proxy's own pids are never remapped.
            let attributed = proxyPIDs.contains(pid) ? pid : effectiveAttributionPID(pid)
            if attributed > 0 {
                mappedConnectionCount += 1
            } else if prev[conn.id] == nil {
                unmappedIn += Int(conn.download)
                unmappedOut += Int(conn.upload)
                if unmappedPorts.count < 8 {
                    unmappedPorts.append(conn.sourcePort)
                }
            }
            newPrevious[conn.id] = TrackedConnection(
                pid: attributed,
                sourcePort: conn.sourcePort,
                transport: conn.transport,
                uploadTotal: conn.upload,
                downloadTotal: conn.download
            )
            if let prevConn = previous,
               shouldReuseTrackedProxyPID(
                   previousSourcePort: prevConn.sourcePort,
                   previousTransport: prevConn.transport,
                   currentSourcePort: conn.sourcePort,
                   currentTransport: conn.transport
               ) {
                let dIn = nonNegativeProxyDelta(current: conn.download, previous: prevConn.downloadTotal)
                let dOut = nonNegativeProxyDelta(current: conn.upload, previous: prevConn.uploadTotal)
                if !staleGap, (dIn > 0 || dOut > 0), prevConn.pid > 0, !proxyPIDs.contains(prevConn.pid) {
                    var c = credits[prevConn.pid] ?? (inBytes: 0, outBytes: 0)
                    c.inBytes += Int(dIn)
                    c.outBytes += Int(dOut)
                    credits[prevConn.pid] = c
                }
                // prevConn.pid == proxyPid → the proxy's own direct connection,
                // not tunneled traffic; keep it on the proxy.
            } else if !staleGap, attributed > 0, !proxyPIDs.contains(attributed) {
                // First observation of a connection. Its session-cumulative
                // bytes are the only snapshot we get if the connection is
                // short-lived (Steam chunk downloads, DNS lookups, …), so
                // credit them directly instead of dropping the bytes. The
                // proxy row's visible bytes bound consumption, so over-crediting
                // a long-lived connection cannot inflate the total.
                let dIn = max(0, conn.download)
                let dOut = max(0, conn.upload)
                if dIn > 0 || dOut > 0 {
                    var c = credits[attributed] ?? (inBytes: 0, outBytes: 0)
                    c.inBytes += Int(dIn)
                    c.outBytes += Int(dOut)
                    credits[attributed] = c
                }
            }
        }

        previousConnections = newPrevious
        stateLock.lock()
        for (pid, credit) in credits where credit.inBytes > 0 || credit.outBytes > 0 {
            pendingCredits.append(PendingProxyCredit(
                timestamp: now,
                pid: pid,
                inBytes: credit.inBytes,
                outBytes: credit.outBytes
            ))
        }
        self.proxyDetected = true
        self.proxyPid = proxyPid
        self.proxyPIDs = proxyPIDs
        isClashVergeProxy = candidate.name == "Clash Verge"
        pidNameCache.merge(portMap.names) { _, new in new }
        lastProxyName = candidate.name
        lastProxyEndpoint = proxyEndpointLabel(candidate.unixSocket ?? candidate.baseURL)
        lastConnectionCount = connections.count
        lastMappedConnectionCount = mappedConnectionCount
        tickCount += 1
        if tickCount % 30 == 0 {
            let pending = pendingCredits.reduce(0) { $0 + $1.inBytes + $1.outBytes }
            DiagnosticLogStore.shared.append("proxy heartbeat connections=\(connections.count) mapped=\(mappedConnectionCount) pending=\(pending) rowVisible=\(lastProxyRowVisible == true ? 1 : 0)")
        }
        stateLock.unlock()
        emitDiagnostic(.detected(
            name: candidate.name,
            endpoint: proxyEndpointLabel(candidate.unixSocket ?? candidate.baseURL),
            connectionCount: connections.count,
            mappedConnectionCount: mappedConnectionCount,
            proxyPID: proxyPid
        ))
        if !credits.isEmpty {
            // Per-app breakdown (pid:in:out) — the core debugging data for
            // "which app did the proxy say was using bytes". Also written to
            // the diagnostics file, not just os_log.
            let detail = credits.keys.sorted()
                .map { "\($0):\(credits[$0]!.inBytes):\(credits[$0]!.outBytes)" }
                .joined(separator: ",")
            let totalIn = credits.values.reduce(0) { $0 + $1.inBytes }
            let totalOut = credits.values.reduce(0) { $0 + $1.outBytes }
            logger.info("proxy credits pids=\(detail, privacy: .public) in=\(totalIn) out=\(totalOut) proxyPid=\(proxyPid ?? 0)")
            DiagnosticLogStore.shared.append("proxy credits pids=\(detail) in=\(totalIn) out=\(totalOut) proxyPid=\(proxyPid ?? 0)")
        }
        if unmappedIn > 0 || unmappedOut > 0 {
            let ports = unmappedPorts.map(String.init).joined(separator: ",")
            logger.info("proxy unmapped connections=\(connections.count - mappedConnectionCount, privacy: .public) in=\(unmappedIn, privacy: .public) out=\(unmappedOut, privacy: .public) ports=\(ports, privacy: .public)")
            DiagnosticLogStore.shared.append("proxy unmapped connections=\(connections.count - mappedConnectionCount) in=\(unmappedIn) out=\(unmappedOut) ports=\(ports)")
        }
        if staleGap {
            let gap = now - lastDetectionAt
            logger.info("proxy attribution resumed after gap=\(gap, privacy: .public)s; outage-window deltas kept on proxy row")
            DiagnosticLogStore.shared.append("proxy attribution resumed after gap=\(gap)s; outage-window deltas kept on proxy row")
        }
        lastDetectionAt = now
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
                    let network: String?
                    let process: String?
                    let processPath: String?
                }
                struct Source: Decodable { let port: Int?; let network: String? }
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
                transport: SocketProtocol(rawValue: c.metadata?.network ?? c.source?.network),
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
        runProcess("/usr/sbin/lsof", ["-w"] + args)
    }

    private func runProcess(_ executable: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
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

    /// Builds a local-port -> owning-pid map for exactly the sockets the proxy
    /// API reported this tick. A full `lsof -iTCP/-iUDP` scan of every socket
    /// on the machine is slow and fails under heavy load (e.g. a Steam
    /// download with dozens of concurrent connections), which left proxy bytes
    /// stranded on the Clash row. Querying only the ports present in the
    /// connection table is fast and reliable regardless of system load.
    private func socketPortMap(for connections: [ProxyConnection]) -> (ports: [SocketKey: Int], names: [Int: String], owners: [SocketKey: SocketOwner]) {
        var ports: [SocketKey: Int] = [:]
        var names: [Int: String] = [:]
        let tcpPorts = connections.compactMap { $0.transport == .tcp ? $0.sourcePort : nil }
        let udpPorts = connections.compactMap { $0.transport == .udp ? $0.sourcePort : nil }
        // lsof accepts a comma-separated port list (-iTCP:80,443,...); chunk
        // large lists so the command line never exceeds comfortable lengths.
        let batchSize = 40
        if !tcpPorts.isEmpty {
            let unique = Array(Set(tcpPorts)).sorted()
            for chunk in stride(from: 0, to: unique.count, by: batchSize) {
                let slice = unique[chunk..<min(chunk + batchSize, unique.count)]
                let list = slice.map(String.init).joined(separator: ",")
                if let out = runLsof(["-nP", "-iTCP:\(list)"]) {
                    collectSocketLines(out, transport: .tcp, into: &ports, names: &names)
                }
            }
        }
        if !udpPorts.isEmpty {
            let list = Array(Set(udpPorts)).sorted().map(String.init).joined(separator: ",")
            if let out = runLsof(["-nP", "-iUDP:\(list)"]) {
                collectSocketLines(out, transport: .udp, into: &ports, names: &names)
            }
        }
        let owners = ports.reduce(into: [SocketKey: SocketOwner]()) { result, entry in
            result[entry.key] = SocketOwner(
                pid: entry.value,
                name: names[entry.value] ?? "",
                startTime: processStartTime(of: entry.value)
            )
        }
        return (ports, names, owners)
    }

    private func collectSocketLines(
        _ output: String,
        transport: SocketProtocol,
        into ports: inout [SocketKey: Int],
        names: inout [Int: String]
    ) {
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int(fields[1]) else { continue }
            if names[pid] == nil {
                names[pid] = String(fields[0])
            }
            guard fields.count >= 9 else { continue }
            let name = fields[8...].joined(separator: " ")
            if name.hasPrefix("TCP ") && !name.contains("->") {
                continue
            }
            if let port = localPort(from: name) {
                let key = SocketKey(protocol: transport, port: port)
                if ports[key] == nil {
                    ports[key] = pid
                }
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
            // A privileged core (e.g. Clash Verge's root-owned verge-mihomo)
            // is invisible to user-level lsof; the lookup instead returns the
            // client processes connected to the socket (loginwindow,
            // distnoted, ...). Validate the pid so those garbage pids never
            // enter proxyPIDs and shadow the real proxy row.
            if let output = runLsof(["-nP", "-U", unixSocket]),
               let pid = firstPID(in: output),
               isLikelyProxyProcess(pid, candidate: candidate) {
                pids.insert(pid)
            }

            // Clash Verge's privileged core keeps its PID next to the socket.
            // This fallback handles the case where lsof cannot inspect the
            // root-owned core process from the app context. The pid is
            // validated like every other source so a stale or recycled value
            // cannot shadow the real proxy row.
            let socketURL = URL(fileURLWithPath: unixSocket)
            let pidURL = socketURL.deletingLastPathComponent()
                .appendingPathComponent("clash-verge-service.core.json")
            if let data = try? Data(contentsOf: pidURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = object["pid"] as? Int,
               isLikelyProxyProcess(pid, candidate: candidate) {
                pids.insert(pid)
            }
        }
        if let pid = resolveProxyPid(port: candidate.port),
           isLikelyProxyProcess(pid, candidate: candidate) {
            pids.insert(pid)
        }
        // Fallback: lsof on a root-owned unix socket is often invisible to the
        // app, and the core.json may be unreadable (root:root 0640). When the
        // candidate is Clash Verge, scan running processes by name so the real
        // core pid is present. Besides fixing the proxy pid, this keeps the
        // proxy's own direct connections out of the credit pool.
        if candidate.name == "Clash Verge" {
            for name in ["verge-mihomo", "mihomo", "clash-verge"] {
                if let output = runProcess("/usr/bin/pgrep", ["-x", name]),
                   let pid = firstPIDFromLines(output) {
                    pids.insert(pid)
                    break
                }
            }
        }
        return pids
    }

    private func firstPIDFromLines(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            if let pid = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
        }
        return nil
    }

    /// True when `pid` belongs to a process plausibly part of the proxy
    /// family (Clash / Mihomo / Surge). Used to reject garbage pids that
    /// user-level `lsof -U` returns for a root-owned unix socket.
    private func isLikelyProxyProcess(_ pid: Int, candidate: Candidate) -> Bool {
        guard let output = runProcess("/bin/ps", ["-p", String(pid), "-o", "comm="]) else { return false }
        let comm = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !comm.isEmpty else { return false }
        let keywords: [String]
        switch candidate.name {
        case "Clash Verge", "Clash":
            keywords = ["clash", "mihomo", "verge"]
        case "Surge":
            keywords = ["surge"]
        default:
            keywords = ["clash", "mihomo", "verge", "surge"]
        }
        return keywords.contains { comm.contains($0) }
    }

    /// Maps a CLI process pid (e.g. node/npm spawned by a terminal) to the
    /// regular GUI application that hosts it, so terminal traffic shows under
    /// the terminal / IDE instead of a short-lived CLI process. GUI pids are
    /// returned unchanged; results are cached for the process's lifetime,
    /// validated against the process start time so a recycled pid re-resolves
    /// instead of inheriting the previous process's host app.
    /// Only called on the attributor queue, so no lock is needed.
    private func effectiveAttributionPID(_ pid: Int) -> Int {
        guard pid > 0 else { return 0 }
        let startTime = processStartTime(of: pid)
        if let cached = guiAncestorCache[pid], cached.startTime == startTime {
            return cached.hostPID
        }
        let resolved = guiAncestorPID(of: pid) ?? pid
        guiAncestorCache[pid] = GuiAncestorCacheEntry(hostPID: resolved, startTime: startTime)
        return resolved
    }

    /// Walks up to 6 parent levels looking for the regular GUI application
    /// (activationPolicy == .regular) hosting `pid`. Falls back to the nearest
    /// registered application (e.g. an Electron helper) if none is regular.
    private func guiAncestorPID(of pid: Int) -> Int? {
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.activationPolicy == .regular {
            return pid
        }
        var current = pid
        for _ in 0..<6 {
            guard let pp = parentPid(of: current), pp > 1 else { break }
            current = pp
            if let app = NSRunningApplication(processIdentifier: pid_t(pp)), app.activationPolicy == .regular {
                return pp
            }
        }
        current = pid
        for _ in 0..<6 {
            guard let pp = parentPid(of: current), pp > 1 else { break }
            current = pp
            if NSRunningApplication(processIdentifier: pid_t(pp)) != nil {
                return pp
            }
        }
        return nil
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
        lastDetectionAt = 0
        stateLock.lock()
        pendingCredits = []
        proxyDetected = false
        proxyPid = nil
        proxyPIDs = []
        sourcePortCache = [:]
        isClashVergeProxy = false
        guiAncestorCache = [:]
        stateLock.unlock()
        emitDiagnostic(.notDetected)
    }

    /// Temporarily disables attribution while the proxy API is unreachable,
    /// keeping `previousConnections` so the next successful poll resumes with
    /// incremental deltas instead of re-crediting session-cumulative bytes.
    /// Stale `pendingCredits` are dropped: their bytes were already recorded
    /// on the proxy row while attribution was suspended, and nettop frames
    /// discard declarations whenever `proxyDetected` is false anyway.
    private func suspendAttribution() {
        stateLock.lock()
        pendingCredits = []
        proxyDetected = false
        proxyPid = nil
        proxyPIDs = []
        isClashVergeProxy = false
        stateLock.unlock()
        emitDiagnostic(.notDetected)
    }

    /// Takes declarations for exactly one nettop frame. A declaration that
    /// cannot be paid by that frame is discarded by the settlement layer;
    /// there is no cross-frame debt or recovery queue.
    private func takeCurrentWindowSnapshot() -> (
        declarations: [PendingProxyCredit],
        proxyDetected: Bool,
        proxyPIDs: Set<Int>,
        isClashVergeProxy: Bool
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let declarations = pendingCredits
        pendingCredits = []
        return (declarations, proxyDetected, proxyPIDs, isClashVergeProxy)
    }

    /// Records this frame's proxy-row visibility and, on a genuine transition,
    /// returns the diagnostic payload. Atomic under the lock so the transition
    /// cannot be consumed while detection is momentarily unavailable (a frame
    /// that races a transient `reset()` would otherwise lose the only
    /// visibility change and never emit the diagnostic again).
    private func noteProxyRowVisibility(_ visible: Bool) -> ProxyRowVisibilityUpdate {
        stateLock.lock()
        defer { stateLock.unlock() }
        let update = recordingProxyRowVisibility(
            visible: visible,
            proxyDetected: proxyDetected,
            lastProxyRowVisible: lastProxyRowVisible,
            diagnostic: (lastProxyName, lastProxyEndpoint, lastConnectionCount, lastMappedConnectionCount, proxyPid)
        )
        if update.changed {
            lastProxyRowVisible = update.newLastVisible
        }
        return update
    }

    private func pidNamesSnapshot() -> [Int: String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pidNameCache
    }

    private func emitStatus(_ newStatus: ProxyStatus) {
        let label: String
        switch newStatus {
        case .disabled: label = "disabled"
        case .detected(let name): label = "detected name=\(name)"
        case .notDetected: label = "notDetected"
        case .secretRequired: label = "secretRequired"
        }
        // Only record transitions; emitStatus is called every tick while
        // detected, and a per-tick line would drown out real state changes.
        if label != lastLoggedStatus {
            lastLoggedStatus = label
            DiagnosticLogStore.shared.append("proxy status=\(label)")
        }
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
