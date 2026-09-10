//
//  Network.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import Foundation
import SwiftUI

class Network {
    @ObservedObject var viewModel = SharedStore.listViewModel
    @ObservedObject var statusDataModel = SharedStore.statusDataModel

    private let interval = 2

    private lazy var runner: NettopRunner = {
        let r = NettopRunner(interval: interval)
        r.onFrame = { [weak self] lines, seconds in
            self?.handleFrame(lines, interval: seconds)
        }
        r.onRestart = {
            SharedStore.trafficSamplingDiagnostics.markNettopRestart()
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
        let rawEntities: [ProcessEntity] = lines.compactMap { line -> ProcessEntity? in
            // The column header is reprinted every frame; it is not a row that
            // failed to parse.
            if isNettopHeaderLine(line) { return nil }
            guard let entity = parser(text: line) else {
                droppedRows += 1
                return nil
            }
            totalInBytes += entity.inBytes
            totalOutBytes += entity.outBytes
            return entity
        }

        SharedStore.trafficSamplingDiagnostics.recordNettopFrame(
            inBytes: totalInBytes,
            outBytes: totalOutBytes,
            capturedAt: capturedAt
        )
        SharedStore.trafficSamplingDiagnostics.recordDroppedNettopRows(droppedRows)

        // Re-attribute only bytes already present in this raw nettop frame.
        // The proxy attributor is a bounded allocator: it cannot add bytes or
        // carry an unpaid declaration into a later frame.
        let entities = SharedStore.proxyAttributor.attributedEntities(rawEntities)

        // nettop is the sole historical byte source. The Network Extension may
        // report app identities for diagnostics, but its records are not a
        // second accounting stream and can never replace this raw frame.
        HelperAttributionRegistry.shared.register(entities: entities)
        SharedStore.recorder.record(
            entities: entities,
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
            self.viewModel.updateData(newItems: entities)
            SharedStore.realtimeRateStore.append(inRate: Double(inRate), outRate: Double(outRate))
            SharedStore.perAppRateStore.update(entities: entities, interval: safeSeconds)
        }
    }

    func parser(text: String) -> ProcessEntity? {
        guard let item = parseNettopCSVFields(text) else { return nil }
        if item.count < 3 {
            return nil
        }
        // Store raw delta bytes; rate is computed once at the aggregation point.
        let inBytes  = max(0, Int(item[1].trimmingCharacters(in: .whitespaces)) ?? 0)
        let outBytes = max(0, Int(item[2].trimmingCharacters(in: .whitespaces)) ?? 0)

        let nameAndPid = item[0].split(separator: ".")
        guard nameAndPid.count >= 2 else {
            return nil
        }
        let pid = nameAndPid[nameAndPid.count - 1]
        var name = nameAndPid
        name.removeLast()

        return ProcessEntity(
            pid: Int(pid) ?? 0,
            name: name.joined(separator: "."),
            inBytes: inBytes,
            outBytes: outBytes
        )
    }
}

/// nettop reprints its column header at the very start of every frame (for
/// example `,bytes_in,bytes_out,`). Those fields are labels, not a process
/// row, so they must not be reported as a row that failed to parse.
func isNettopHeaderLine(_ line: String) -> Bool {
    line.contains("bytes_in") || line.contains("bytes_out")
}

/// Parse the small CSV subset emitted by nettop. Process names can be quoted
/// and contain commas, so splitting on every comma is not safe.
func parseNettopCSVFields(_ text: String) -> [String]? {    var fields: [String] = []
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
