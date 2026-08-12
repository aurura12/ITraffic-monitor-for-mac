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
        r.onFrame = { [weak self] lines in
            self?.handleFrame(lines)
        }
        return r
    }()

    public func startListenNetwork() {
        runner.start()
    }

    public func stopListenNetwork() {
        runner.stop()
    }

    private func handleFrame(_ lines: [String]) {
        var totalInBytes = 0
        var totalOutBytes = 0
        let rawEntities: [ProcessEntity] = lines.compactMap { line -> ProcessEntity? in
            guard let entity = parser(text: line) else { return nil }
            totalInBytes += entity.inBytes
            totalOutBytes += entity.outBytes
            return entity
        }

        // Re-attribute traffic that nettop credited to a local proxy / VPN
        // back to the real apps. Totals stay the raw interface bytes; only the
        // per-entity distribution changes.
        let entities = SharedStore.proxyAttributor.attributedEntities(rawEntities)

        // Persist this frame's deltas into the minute-bucket history.
        SharedStore.recorder.record(entities: entities)

        // parser stores raw delta bytes; convert to bytes/sec for the status bar.
        let inRate  = totalInBytes  / interval
        let outRate = totalOutBytes / interval

        DispatchQueue.main.async {
            self.statusDataModel.update(totalInBytes: inRate, totalOutBytes: outRate)
            self.viewModel.updateData(newItems: entities)
            SharedStore.realtimeRateStore.append(inRate: Double(inRate), outRate: Double(outRate))
            SharedStore.perAppRateStore.update(entities: entities, interval: self.interval)
        }
    }

    func parser(text: String) -> ProcessEntity? {
        let item = text.split(separator: ",")
        if item.count < 3 {
            return nil
        }
        // Store raw delta bytes; rate is computed once at the aggregation point.
        let inBytes  = Int(item[1]) ?? 0
        let outBytes = Int(item[2]) ?? 0

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
