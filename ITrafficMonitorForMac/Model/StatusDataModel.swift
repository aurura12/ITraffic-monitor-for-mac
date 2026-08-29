//
//  StatusDataModel.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import Foundation

struct TrafficSamplingSnapshot: Equatable {
    var nettopStatus: NettopSamplingStatus = .waiting
    var lastNettopSampleAt: Date?
    var latestNettopDelta: UTunTrafficCounters?
    var latestExternalDelta: UTunTrafficCounters?
    var latestUTunDelta: UTunTrafficCounters?
}

final class TrafficSamplingDiagnostics: ObservableObject {
    @Published private(set) var snapshot = TrafficSamplingSnapshot()

    private let lock = NSLock()
    private var value = TrafficSamplingSnapshot()

    func recordNettopFrame(inBytes: Int, outBytes: Int, capturedAt: Date) {
        update { snapshot in
            snapshot.nettopStatus = nextNettopSamplingStatus(snapshot.nettopStatus, event: .frame)
            snapshot.lastNettopSampleAt = capturedAt
            snapshot.latestNettopDelta = UTunTrafficCounters(inBytes: max(0, inBytes), outBytes: max(0, outBytes))
        }
    }

    func markNettopRestart() {
        update { snapshot in
            snapshot.nettopStatus = nextNettopSamplingStatus(snapshot.nettopStatus, event: .restart)
        }
    }

    func recordReferenceSample(_ sample: TrafficReferenceSample) {
        update { snapshot in
            snapshot.latestExternalDelta = sample.externalDelta
            snapshot.latestUTunDelta = sample.utunDelta
        }
    }

    private func update(_ transform: (inout TrafficSamplingSnapshot) -> Void) {
        lock.lock()
        transform(&value)
        let copy = value
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = copy
        }
    }
}

class StatusDataModel: ObservableObject {
    @Published var totalInBytes: Int = 0
    @Published var totalOutBytes: Int = 0
    
    public func update(totalInBytes: Int, totalOutBytes: Int) {
        self.totalInBytes = totalInBytes
        self.totalOutBytes = totalOutBytes
    }
}
