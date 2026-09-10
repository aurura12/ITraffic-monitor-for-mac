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
    /// Cumulative nettop rows that could not be parsed, so their bytes are
    /// missing from the recorded totals.
    var droppedNettopRows: Int = 0
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

    /// Counts nettop rows that failed to parse. Their bytes never enter the
    /// totals, so a non-zero value means recorded traffic is understated.
    func recordDroppedNettopRows(_ count: Int) {
        guard count > 0 else { return }
        update { snapshot in
            snapshot.droppedNettopRows += count
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
