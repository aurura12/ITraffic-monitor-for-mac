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

/// The single app currently using the most bandwidth, shown in the menu-bar
/// popover. Identity is the `appKey`, so several PIDs of one app merge.
struct LiveAppRate {
    let appKey: String
    let displayName: String
    let inRate: Double
    let outRate: Double
}

final class PerAppRateStore: ObservableObject {
    @Published var latest: [String: RatePair] = [:]
    /// The busiest app in the last frame, or nil when nothing is active.
    @Published var topApp: LiveAppRate?

    /// Aggregate one frame's entities into rates (bytes/sec) keyed by appKey.
    /// Call on the main thread.
    func update(entities: [ProcessEntity], interval: TimeInterval) {
        guard interval > 0 else { return }
        var d: [String: RatePair] = [:]
        var names: [String: String] = [:]
        for e in entities where e.inBytes > 0 || e.outBytes > 0 {
            let key = e.appKey
            let r = d[key] ?? RatePair(inRate: 0, outRate: 0)
            d[key] = RatePair(
                inRate: r.inRate + Double(e.inBytes) / interval,
                outRate: r.outRate + Double(e.outBytes) / interval
            )
            if names[key] == nil {
                names[key] = e.displayName
            }
        }
        latest = d
        topApp = d
            .max { $0.value.inRate + $0.value.outRate < $1.value.inRate + $1.value.outRate }
            .map {
                LiveAppRate(
                    appKey: $0.key,
                    displayName: names[$0.key] ?? $0.key,
                    inRate: $0.value.inRate,
                    outRate: $0.value.outRate
                )
            }
    }

    /// Drop the live rates, e.g. when sampling stops, so the UI does not keep
    /// showing the last frame's values.
    func clear() {
        latest = [:]
        topApp = nil
    }
}
