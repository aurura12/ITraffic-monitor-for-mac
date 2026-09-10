//
//  PerAppRateStore.swift
//  ITrafficMonitorForMac
//
//  Latest per-app network rates, updated every frame (2s). Only the
//  app detail view should observe this — the whole dictionary is
//  replaced each update, so list rows reading it would re-render too.
//

import Foundation

struct RatePair {
    var inRate: Double
    var outRate: Double
}

final class PerAppRateStore: ObservableObject {
    @Published var latest: [String: RatePair] = [:]

    /// Aggregate one frame's entities into rates (bytes/sec) keyed by appKey.
    /// Call on the main thread.
    func update(entities: [ProcessEntity], interval: TimeInterval) {
        guard interval > 0 else { return }
        var d: [String: RatePair] = [:]
        for e in entities where e.inBytes > 0 || e.outBytes > 0 {
            let key = e.appKey
            let r = d[key] ?? RatePair(inRate: 0, outRate: 0)
            d[key] = RatePair(
                inRate: r.inRate + Double(e.inBytes) / interval,
                outRate: r.outRate + Double(e.outBytes) / interval
            )
        }
        latest = d
    }

    /// Drop the live rates, e.g. when sampling stops, so the UI does not keep
    /// showing the last frame's values.
    func clear() {
        latest = [:]
    }
}
