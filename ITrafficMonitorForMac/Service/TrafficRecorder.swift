//
//  TrafficRecorder.swift
//  ITrafficMonitorForMac
//
//  Persists each finalized frame as an idempotent sample. This keeps the
//  current minute queryable and makes a crash/replay unable to duplicate a
//  frame.
//

import Foundation

final class TrafficRecorder {

    private let database = TrafficDatabase()

    /// All mutations happen on this queue; `record` is the only entry point.
    private let queue = DispatchQueue(label: "traffic-recorder", qos: .utility)

    private let calendar = Calendar.current

    // MARK: - Recording

    /// Persist one finalized frame. The nettop path supplies the original raw
    /// totals so the database can reject any non-conservative result.
    func record(
        entities: [ProcessEntity],
        sampleID: String = UUID().uuidString,
        capturedAt: Date = Date(),
        rawInBytes: Int? = nil,
        rawOutBytes: Int? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let allocations = self.allocations(from: entities)
            let totalIn = rawInBytes ?? allocations.reduce(0) { $0 + $1.inBytes }
            let totalOut = rawOutBytes ?? allocations.reduce(0) { $0 + $1.outBytes }
            self.database.commitSample(self.sample(
                id: sampleID,
                capturedAt: capturedAt,
                rawInBytes: totalIn,
                rawOutBytes: totalOut,
                allocations: allocations
            ))
        }
    }

    /// Wait until all queued frame commits have completed (e.g. on quit).
    func flush() {
        queue.sync {
            // Every frame is committed before it leaves this queue.
        }
    }

    private func allocations(from entities: [ProcessEntity]) -> [TrafficSampleAllocation] {
        var grouped: [String: TrafficSampleAllocation] = [:]
        for entity in entities where entity.inBytes > 0 || entity.outBytes > 0 {
            let allocation = TrafficSampleAllocation(
                appKey: entity.appKey,
                displayName: entity.displayName,
                inBytes: max(0, entity.inBytes),
                outBytes: max(0, entity.outBytes)
            )
            if let existing = grouped[allocation.appKey] {
                grouped[allocation.appKey] = TrafficSampleAllocation(
                    appKey: allocation.appKey,
                    displayName: existing.displayName,
                    inBytes: existing.inBytes + allocation.inBytes,
                    outBytes: existing.outBytes + allocation.outBytes
                )
            } else {
                grouped[allocation.appKey] = allocation
            }
        }
        return Array(grouped.values)
    }

    private func sample(
        id: String,
        capturedAt: Date,
        rawInBytes: Int,
        rawOutBytes: Int,
        allocations: [TrafficSampleAllocation]
    ) -> TrafficSample {
        let bucketStart = Int(capturedAt.timeIntervalSince1970 / 60) * 60
        let (day, hour) = Self.dayAndHour(for: capturedAt, calendar: calendar)
        return TrafficSample(
            id: id,
            capturedAtMs: Int64(capturedAt.timeIntervalSince1970 * 1_000),
            bucketStart: bucketStart,
            day: day,
            hour: hour,
            rawInBytes: max(0, rawInBytes),
            rawOutBytes: max(0, rawOutBytes),
            allocations: allocations
        )
    }

    // MARK: - Query passthrough

    func topApps(start: Int, end: Int, limit: Int = 20, completion: @escaping ([AppTrafficRow]) -> Void) {
        database.topApps(start: start, end: end, limit: limit, completion: completion)
    }

    func totalTraffic(start: Int, end: Int, completion: @escaping (TrafficTotal) -> Void) {
        database.totalTraffic(start: start, end: end, completion: completion)
    }

    func trafficMatrix(start: Int, end: Int, completion: @escaping ([TrafficMatrixRow]) -> Void) {
        database.trafficMatrix(start: start, end: end, completion: completion)
    }

    func dailyTraffic(start: Int, end: Int, appKey: String? = nil, completion: @escaping ([DayTrafficRow]) -> Void) {
        database.dailyTraffic(start: start, end: end, appKey: appKey, completion: completion)
    }

    func trafficSeries(start: Int, end: Int, granularity: TimeSeriesGranularity,
                       completion: @escaping ([TrafficSeriesPoint]) -> Void) {
        database.trafficSeries(start: start, end: end, granularity: granularity, completion: completion)
    }

    func topAppsWithPeak(start: Int, end: Int, limit: Int = 20,
                         completion: @escaping ([AppPeakTrafficRow]) -> Void) {
        database.topAppsWithPeak(start: start, end: end, limit: limit, completion: completion)
    }

    func exportRows(start: Int, end: Int, granularity: ExportGranularity,
                    completion: @escaping ([ExportTrafficRow]) -> Void) {
        database.exportRows(start: start, end: end, granularity: granularity, completion: completion)
    }

    // MARK: - Helpers

    /// Local day (local days since 1970-01-01, timezone-safe) and hour (0-23).
    static func dayAndHour(for date: Date, calendar: Calendar) -> (day: Int, hour: Int) {
        let comps = calendar.dateComponents([.day, .hour], from: date)
        let hour = comps.hour ?? 0
        return (dayIndex(for: date, calendar: calendar), hour)
    }
}
