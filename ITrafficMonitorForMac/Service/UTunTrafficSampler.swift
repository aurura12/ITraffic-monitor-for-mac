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

enum UTunSamplerStatus: Equatable {
    case waiting
    case active
    case unavailable
}

func parseUTunInterfaceCounters(_ output: String) -> UTunInterfaceCounters? {
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
    for line in lines.drop(while: { $0 != header }) {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let name = fields.first, name.lowercased().hasPrefix("utun"),
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
    guard current.inBytes >= previous.inBytes, current.outBytes >= previous.outBytes else { return nil }
    return UTunTrafficCounters(
        inBytes: current.inBytes - previous.inBytes,
        outBytes: current.outBytes - previous.outBytes
    )
}

final class UTunTrafficSampler: ObservableObject {
    @Published private(set) var status: UTunSamplerStatus = .waiting
    private let queue = DispatchQueue(label: "utun-traffic-sampler", qos: .utility)
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var previous: UTunInterfaceCounters?
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
            self.stateLock.lock()
            self.pendingDelta = nil
            self.stateLock.unlock()
        }
    }

    /// Atomically consumes the latest interval. A sample is never reused by
    /// multiple nettop frames, and an unavailable sample naturally returns nil.
    func consumeLatestDelta() -> UTunTrafficCounters? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let result = pendingDelta
        pendingDelta = nil
        return result
    }

    private func sample() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-ib"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard let current = parseUTunInterfaceCounters(output) else {
                publishStatus(.unavailable)
                return
            }
            defer { previous = current }
            guard let previous, let delta = utunDelta(previous: previous, current: current) else { return }
            publishStatus(.active)
            stateLock.lock()
            pendingDelta = delta
            stateLock.unlock()
        } catch {
            // The free sampler is optional. nettop and proxy attribution keep
            // working when macOS denies netstat's interface counters.
        }
    }

    private func publishStatus(_ newStatus: UTunSamplerStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
    }
}
