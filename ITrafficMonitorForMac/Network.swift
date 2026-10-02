//
//  Network.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import Foundation
import SwiftUI

class Network {
    @ObservedObject var statusDataModel = SharedStore.statusDataModel

    private let interval = 2

    private lazy var runner: NettopRunner = {
        let r = NettopRunner(interval: interval)
        r.onFrame = { [weak self] lines, seconds in
            self?.handleFrame(lines, interval: seconds)
        }
        r.onRestart = {
            SharedStore.trafficSamplingDiagnostics.markNettopRestart()
            // Sampling may not resume (a restart can keep failing), so drop the
            // now-stale live values rather than showing the last frame's rates.
            DispatchQueue.main.async {
                SharedStore.statusDataModel.update(totalInBytes: 0, totalOutBytes: 0)
            }
        }
        return r
    }()

    public func startListenNetwork() {
        runner.start()
    }

    public func stopListenNetwork() {
        runner.stop()
    }

    private func handleFrame(_ lines: [String], interval seconds: TimeInterval) {
        let capturedAt = Date()
        let sampleID = UUID().uuidString
        var totalInBytes = 0
        var totalOutBytes = 0
        var droppedRows = 0
        for line in lines {
            // The column header is reprinted every frame; it is not a row that
            // failed to parse.
            if isNettopHeaderLine(line) { continue }
            guard let row = parser(text: line) else {
                droppedRows += 1
                continue
            }
            totalInBytes += row.inBytes
            totalOutBytes += row.outBytes
        }

        SharedStore.trafficSamplingDiagnostics.recordNettopFrame(
            inBytes: totalInBytes,
            outBytes: totalOutBytes,
            capturedAt: capturedAt
        )
        SharedStore.trafficSamplingDiagnostics.recordDroppedNettopRows(droppedRows)

        // nettop is the sole byte source; record the frame's raw totals.
        SharedStore.recorder.record(
            sampleID: sampleID,
            capturedAt: capturedAt,
            rawInBytes: totalInBytes,
            rawOutBytes: totalOutBytes
        )

        // parser stores raw delta bytes; convert to bytes/sec for the status
        // bar using the frame's measured interval, not a fixed constant.
        let safeSeconds = max(seconds, 0.001)
        let inRate  = Int(Double(totalInBytes) / safeSeconds)
        let outRate = Int(Double(totalOutBytes) / safeSeconds)

        DispatchQueue.main.async {
            self.statusDataModel.update(totalInBytes: inRate, totalOutBytes: outRate)
            SharedStore.realtimeRateStore.append(inRate: Double(inRate), outRate: Double(outRate))
        }
    }

    /// Parse one nettop CSV row into its download / upload delta. The name field
    /// may be quoted and contain commas, so the row is still split as CSV, but
    /// only the two byte columns matter for total accounting.
    func parser(text: String) -> (inBytes: Int, outBytes: Int)? {
        guard let item = parseNettopCSVFields(text), item.count >= 3 else { return nil }
        // Store raw delta bytes; reject a row whose byte fields are not numbers
        // instead of coercing them to 0, so malformed input is counted rather
        // than silently kept.
        guard let parsedIn = Int(item[1].trimmingCharacters(in: .whitespaces)),
              let parsedOut = Int(item[2].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        // nettop can report a negative delta when a counter resets; clamp that
        // to 0 rather than dropping the row's other direction.
        return (inBytes: max(0, parsedIn), outBytes: max(0, parsedOut))
    }
}

/// nettop reprints its column header at the very start of every frame (for
/// example `,bytes_in,bytes_out,`). Those fields are labels, not a process
/// row, so they must not be reported as a row that failed to parse.
///
/// Match by field position rather than by substring: a process literally named
/// `bytes_in` is still a real row.
func isNettopHeaderLine(_ line: String) -> Bool {
    guard let fields = parseNettopCSVFields(line), fields.count >= 3 else { return false }
    let first = fields[0].trimmingCharacters(in: .whitespaces)
    let second = fields[1].trimmingCharacters(in: .whitespaces)
    let third = fields[2].trimmingCharacters(in: .whitespaces)
    return first.isEmpty && second == "bytes_in" && third == "bytes_out"
}

/// Parse the small CSV subset emitted by nettop. Process names can be quoted
/// and contain commas, so splitting on every comma is not safe.
func parseNettopCSVFields(_ text: String) -> [String]? {
    var fields: [String] = []
    var field = ""
    var quoted = false
    let characters = Array(text)
    var index = 0

    while index < characters.count {
        let character = characters[index]
        if character == "\"" {
            if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                field.append("\"")
                index += 2
                continue
            }
            quoted.toggle()
        } else if character == "," && !quoted {
            fields.append(field)
            field = ""
        } else {
            field.append(character)
        }
        index += 1
    }

    guard !quoted else { return nil }
    fields.append(field)
    return fields
}
