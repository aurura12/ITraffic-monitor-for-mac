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
    func update(entities: [ProcessEntity], interval: Int) {
        guard interval > 0 else { return }
        var d: [String: RatePair] = [:]
        for e in entities where e.inBytes > 0 || e.outBytes > 0 {
            let r = d[e.appKey] ?? RatePair(inRate: 0, outRate: 0)
            d[e.appKey] = RatePair(
                inRate: r.inRate + Double(e.inBytes) / Double(interval),
                outRate: r.outRate + Double(e.outBytes) / Double(interval)
            )
        }
        latest = d
    }
}
