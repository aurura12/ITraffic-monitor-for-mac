//
//  UTunTrafficSampler.swift
//  ITrafficMonitorForMac
//

import Foundation
import Combine

struct UTunTrafficCounters: Equatable {
    let inBytes: Int
    let outBytes: Int
}

typealias UTunInterfaceCounters = UTunTrafficCounters

struct TrafficReferenceSample: Equatable {
    let externalDelta: UTunTrafficCounters?
    let utunDelta: UTunTrafficCounters?
    let sampledAt: Date
}

enum NettopSamplingStatus: Equatable {
    case waiting
    case active
    case restarting
}

enum NettopSamplingEvent {
    case frame
    case restart
}

func nextNettopSamplingStatus(
    _ status: NettopSamplingStatus,
    event: NettopSamplingEvent
) -> NettopSamplingStatus {
    switch event {
    case .frame: return .active
    case .restart: return .restarting
    }
}

enum UTunSamplerStatus: Equatable {
    case waiting
    case active
    case unavailable
}

func parseUTunInterfaceCounters(_ output: String) -> UTunInterfaceCounters? {
    parseInterfaceCounters(output) { $0.lowercased().hasPrefix("utun") }
}

/// Parse one link-level row per physical external interface. Address rows for
/// the same interface are intentionally ignored so counters are not doubled.
func parseExternalInterfaceCounters(_ output: String) -> UTunInterfaceCounters? {
    parseInterfaceCounters(output) {
        $0.lowercased().hasPrefix("en") || $0.lowercased().hasPrefix("pdp_ip")
    }
}

private func parseInterfaceCounters(
    _ output: String,
    matching matcher: (String) -> Bool
) -> UTunInterfaceCounters? {
    let lines = output.split(whereSeparator: \.isNewline)
    guard let header = lines.first(where: { $0.localizedCaseInsensitiveContains("ibytes") && $0.localizedCaseInsensitiveContains("obytes") }) else {
        return nil
    }

    let columns = header.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard let inIndex = columns.firstIndex(where: { $0.caseInsensitiveCompare("Ibytes") == .orderedSame }),
          let outIndex = columns.firstIndex(where: { $0.caseInsensitiveCompare("Obytes") == .orderedSame }) else {
        return nil
    }

    var totalIn = 0
    var totalOut = 0
    var found = false
    var seenInterfaces = Set<String>()
    for line in lines.drop(while: { $0 != header }) {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let name = fields.first,
              matcher(name),
              fields.count > 2, fields[2].hasPrefix("<Link#"),
              seenInterfaces.insert(name).inserted,
              fields.indices.contains(inIndex), fields.indices.contains(outIndex),
              let inBytes = Int(fields[inIndex]), let outBytes = Int(fields[outIndex]),
              inBytes >= 0, outBytes >= 0 else { continue }
        totalIn += inBytes
        totalOut += outBytes
        found = true
    }
    return found ? UTunInterfaceCounters(inBytes: totalIn, outBytes: totalOut) : nil
}

func utunDelta(previous: UTunInterfaceCounters, current: UTunInterfaceCounters) -> UTunTrafficCounters? {
    interfaceCounterDelta(previous: previous, current: current)
}

func interfaceCounterDelta(previous: UTunInterfaceCounters, current: UTunInterfaceCounters) -> UTunTrafficCounters? {
    guard current.inBytes >= previous.inBytes, current.outBytes >= previous.outBytes else { return nil }
    return UTunTrafficCounters(
        inBytes: current.inBytes - previous.inBytes,
        outBytes: current.outBytes - previous.outBytes
    )
}

final class UTunTrafficSampler: ObservableObject {
    @Published private(set) var status: UTunSamplerStatus = .waiting
    @Published private(set) var externalStatus: UTunSamplerStatus = .waiting
    var onReferenceSample: ((TrafficReferenceSample) -> Void)?
    private let queue = DispatchQueue(label: "utun-traffic-sampler", qos: .utility)
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var previous: UTunInterfaceCounters?
    private var previousExternal: UTunInterfaceCounters?
    private var pendingDelta: UTunTrafficCounters?

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(2))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.previous = nil
            self.previousExternal = nil
            self.stateLock.lock()
            self.pendingDelta = nil
            self.stateLock.unlock()
        }
    }

    /// Atomically consumes all accumulated intervals. The sampler is not part
    /// of historical accounting, but if a diagnostic caller uses it, samples
    /// collected between reads are not overwritten or lost.
    func consumeLatestDelta() -> UTunTrafficCounters? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let result = pendingDelta
        pendingDelta = nil
        return result
    }

    private func sample() {
        // Bounded: a stuck netstat must not wedge the sampler queue. A nil
        // result also covers spawn failures, which happen when macOS denies
        // netstat's interface counters.
        guard let output = runProcessCollectingOutput(
            executable: "/usr/sbin/netstat",
            arguments: ["-ib"],
            timeout: 2
        ) else {
            publishStatus(.unavailable)
            publishExternalStatus(.unavailable)
            return
        }

        let current = parseUTunInterfaceCounters(output)
        let currentExternal = parseExternalInterfaceCounters(output)
        guard current != nil || currentExternal != nil else {
            publishStatus(.unavailable)
            publishExternalStatus(.unavailable)
            return
        }
        var utunDelta: UTunTrafficCounters?
        if let current {
            if let previous {
                utunDelta = interfaceCounterDelta(previous: previous, current: current)
            }
            self.previous = current
        }
        if let currentExternal {
            let delta = previousExternal.map {
                interfaceCounterDelta(previous: $0, current: currentExternal)
            } ?? nil
            previousExternal = currentExternal
            if delta != nil { publishExternalStatus(.active) }
            if let delta {
                publishReferenceSample(TrafficReferenceSample(
                    externalDelta: delta,
                    utunDelta: utunDelta ?? nil,
                    sampledAt: Date()
                ))
            }
        } else {
            publishExternalStatus(.unavailable)
        }
        if let utunDelta {
            publishStatus(.active)
            stateLock.lock()
            let accumulated = pendingDelta ?? UTunTrafficCounters(inBytes: 0, outBytes: 0)
            pendingDelta = UTunTrafficCounters(
                inBytes: accumulated.inBytes + utunDelta.inBytes,
                outBytes: accumulated.outBytes + utunDelta.outBytes
            )
            stateLock.unlock()
            if currentExternal == nil {
                publishReferenceSample(TrafficReferenceSample(
                    externalDelta: nil,
                    utunDelta: utunDelta,
                    sampledAt: Date()
                ))
            }
        }
    }

    private func publishStatus(_ newStatus: UTunSamplerStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
    }

    private func publishExternalStatus(_ newStatus: UTunSamplerStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.externalStatus = newStatus
        }
    }

    private func publishReferenceSample(_ sample: TrafficReferenceSample) {
        onReferenceSample?(sample)
    }
}
