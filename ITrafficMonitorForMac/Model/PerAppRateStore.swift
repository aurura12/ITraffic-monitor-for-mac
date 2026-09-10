//
//  PerAppRateStore.swift
//  ITrafficMonitorForMac
//
//  Latest per-app network rates, updated every frame (2s). Only the
//  app detail view should observe this — the whole dictionary is
//  replaced each update, so list rows reading it would re-render too.
//

import Cocoa
import Foundation

struct RatePair {
    var inRate: Double
    var outRate: Double
}

/// One app's live rate for the current-processes list.
struct LiveProcessRow: Identifiable {
    let id: String
    let displayName: String
    let icon: NSImage?
    let inRate: Double
    let outRate: Double

    var totalRate: Double { inRate + outRate }
}

final class PerAppRateStore: ObservableObject {
    @Published var latest: [String: RatePair] = [:]
    /// Current apps with traffic, highest combined rate first. Used by the
    /// menu-bar popover's live per-process list.
    @Published var topProcesses: [LiveProcessRow] = []

    /// Aggregate one frame's entities into rates (bytes/sec) keyed by appKey.
    /// Call on the main thread.
    func update(entities: [ProcessEntity], interval: TimeInterval) {
        guard interval > 0 else { return }
        var d: [String: RatePair] = [:]
        var names: [String: (String, NSImage?)] = [:]
        for e in entities where e.inBytes > 0 || e.outBytes > 0 {
            let key = e.appKey
            let r = d[key] ?? RatePair(inRate: 0, outRate: 0)
            d[key] = RatePair(
                inRate: r.inRate + Double(e.inBytes) / interval,
                outRate: r.outRate + Double(e.outBytes) / interval
            )
            if names[key] == nil {
                names[key] = (e.displayName, e.icon)
            }
        }
        latest = d
        topProcesses = d
            .map { key, rate in
                LiveProcessRow(
                    id: key,
                    displayName: names[key]?.0 ?? key,
                    icon: names[key]?.1 ?? nil,
                    inRate: rate.inRate,
                    outRate: rate.outRate
                )
            }
            .sorted { $0.totalRate > $1.totalRate }
    }
}
