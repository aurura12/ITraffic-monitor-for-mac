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

/// One app's live rate for the current-apps list. Identity is the `appKey`, so
/// several PIDs of the same app are merged into a single row.
struct LiveAppRow: Identifiable {
    let id: String
    let displayName: String
    let inRate: Double
    let outRate: Double

    var totalRate: Double { inRate + outRate }
}

final class PerAppRateStore: ObservableObject {
    @Published var latest: [String: RatePair] = [:]
    /// Current apps with traffic, highest combined rate first. Used by the
    /// menu-bar popover's live list.
    @Published var topApps: [LiveAppRow] = []

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
        topApps = d
            .map { key, rate in
                LiveAppRow(
                    id: key,
                    displayName: names[key] ?? key,
                    inRate: rate.inRate,
                    outRate: rate.outRate
                )
            }
            .sorted { $0.totalRate > $1.totalRate }
    }

    /// Drop the live values, e.g. when sampling stops, so the UI does not keep
    /// showing the last frame's rates.
    func clear() {
        latest = [:]
        topApps = []
    }
}
