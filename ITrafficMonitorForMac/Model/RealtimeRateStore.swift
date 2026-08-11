//
//  RealtimeRateStore.swift
//  ITrafficMonitorForMac
//
//  Ring buffer of recent total network rates, feeding the Realtime tab
//  chart. Capacity 300 samples (2s cadence ≈ 10 minutes).
//

import Foundation

struct RateSample: Identifiable {
    let id = UUID()
    let date: Date
    let inRate: Double
    let outRate: Double
}

class RealtimeRateStore: ObservableObject {
    @Published var samples: [RateSample] = []

    private let capacity = 300

    func append(inRate: Double, outRate: Double) {
        let sample = RateSample(date: Date(), inRate: inRate, outRate: outRate)
        if samples.count >= capacity {
            samples.removeFirst(samples.count - capacity + 1)
        }
        samples.append(sample)
    }

    func clear() {
        samples.removeAll()
    }
}
