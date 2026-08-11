//
//  TrafficRecorder.swift
//  ITrafficMonitorForMac
//
//  Accumulates per-frame deltas into the current minute bucket in memory,
//  then flushes the finished bucket to SQLite as a single transaction.
//  `record(entities:)` runs on the nettop runner queue (not main thread);
//  only the in-memory dict is touched there, and it is guarded by the
//  recorder's own serial queue to stay race-free.
//

import Foundation

final class TrafficRecorder {

    private let database = TrafficDatabase()

    /// All mutations happen on this queue; `record` is the only entry point.
    private let queue = DispatchQueue(label: "traffic-recorder", qos: .utility)

    /// App key -> (displayName, inBytes, outBytes) for the current minute.
    private var currentDict: [String: (name: String, inBytes: Int, outBytes: Int)] = [:]
    private var currentBucketStart: Int = 0
    private var currentDay = 0
    private var currentHour = 0

    private let calendar = Calendar.current
    private var lastPruneCheck = 0

    init() {
        let now = Date()
        currentBucketStart = Int(now.timeIntervalSince1970 / 60) * 60
        (currentDay, currentHour) = Self.dayAndHour(for: now, calendar: calendar)
    }

    // MARK: - Recording

    /// Accumulate one frame's entities into the current minute bucket.
    /// If the wall clock moved into a new minute, flush the previous bucket first.
    func record(entities: [ProcessEntity]) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let bucketStart = Int(now.timeIntervalSince1970 / 60) * 60

            if bucketStart != self.currentBucketStart {
                self.flushLocked()
                self.currentBucketStart = bucketStart
                (self.currentDay, self.currentHour) = Self.dayAndHour(for: now, calendar: self.calendar)
                self.currentDict.removeAll(keepingCapacity: true)
            }

            for entity in entities {
                // Skip idle processes so the history stays lean — an app
                // with no traffic simply has no bucket rows.
                guard entity.inBytes > 0 || entity.outBytes > 0 else { continue }
                let key = entity.appKey
                if var entry = self.currentDict[key] {
                    entry.inBytes += entity.inBytes
                    entry.outBytes += entity.outBytes
                    self.currentDict[key] = entry
                } else {
                    self.currentDict[key] = (entity.displayName, entity.inBytes, entity.outBytes)
                }
            }

            self.maybePrune(now: now)
        }
    }

    /// Flush any pending bucket immediately (e.g. on quit). Blocks until the
    /// in-memory bucket is handed to the database queue.
    func flush() {
        queue.sync {
            flushLocked()
        }
    }

    private func flushLocked() {
        guard !currentDict.isEmpty else { return }
        let rows = currentDict.map { key, value in
            AppTrafficRow(appKey: key, displayName: value.name, inBytes: value.inBytes, outBytes: value.outBytes)
        }
        let batch = TrafficBatch(
            bucketStart: currentBucketStart,
            day: currentDay,
            hour: currentHour,
            rows: rows
        )
        database.commitBatch(batch)
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

    func heatmap(days: Int, completion: @escaping ([HeatmapCell]) -> Void) {
        database.heatmap(days: days, completion: completion)
    }

    func exportRows(start: Int, end: Int, granularity: ExportGranularity,
                    completion: @escaping ([ExportTrafficRow]) -> Void) {
        database.exportRows(start: start, end: end, granularity: granularity, completion: completion)
    }

    // MARK: - Helpers

    private func maybePrune(now: Date) {
        let t = Int(now.timeIntervalSince1970)
        if t - lastPruneCheck > 3600 {
            lastPruneCheck = t
            database.pruneIfNeeded()
        }
    }

    /// Local day (local days since 1970-01-01, timezone-safe) and hour (0-23).
    static func dayAndHour(for date: Date, calendar: Calendar) -> (day: Int, hour: Int) {
        let comps = calendar.dateComponents([.day, .hour], from: date)
        let hour = comps.hour ?? 0
        return (dayIndex(for: date, calendar: calendar), hour)
    }
}
