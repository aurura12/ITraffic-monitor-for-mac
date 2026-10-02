//
//  StatusDataModel.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import Foundation

/// A download / upload byte-count pair, used by the sampling diagnostics.
struct TrafficCounters: Equatable {
    let inBytes: Int
    let outBytes: Int
}

/// Lifecycle of the nettop sampler, surfaced in Settings diagnostics.
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

struct TrafficSamplingSnapshot: Equatable {
    var nettopStatus: NettopSamplingStatus = .waiting
    var lastNettopSampleAt: Date?
    var latestNettopDelta: TrafficCounters?
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
            snapshot.latestNettopDelta = TrafficCounters(inBytes: max(0, inBytes), outBytes: max(0, outBytes))
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
