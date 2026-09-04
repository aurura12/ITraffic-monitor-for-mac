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

    private let database: TrafficDatabase
    private let backfillQueue = DispatchQueue(label: "traffic-recorder-backfill", qos: .utility)

    /// All mutations happen on this queue; `record` is the only entry point.
    private let queue = DispatchQueue(label: "traffic-recorder", qos: .utility)

    private let calendar = Calendar.current

    /// Minute bucket of the newest sweep already performed. Touched only on `queue`.
    private var lastRolledUpBucket: Int?

    /// One-minute buckets folded per backfill transaction (~1 hour, up to
    /// ~1,800 frames) so a large legacy ledger is archived in bounded chunks
    /// that let frame commits and dashboard reads interleave on `dbQueue`.
    private static let backfillChunkBuckets = 60

    init(databaseURL: URL? = nil) {
        self.database = TrafficDatabase(databaseURL: databaseURL)
        startBackfill(finalCutoff: Self.minuteBucket(for: Date()))
    }

    /// Whole-minute bucket (epoch seconds of the minute start) for a date.
    /// Shared by the sample ledger's `bucketStart` and the rollup cutoff so
    /// the write path and the archival sweep never disagree.
    static func minuteBucket(for date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60) * 60
    }

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
            self.rollUpIfNeeded(capturedAt: capturedAt)
        }
    }

    /// Wait until all queued frame commits have completed (e.g. on quit).
    func flush() {
        queue.sync {
            // Every frame is committed before it leaves this queue.
        }
    }

    /// Fire at most once per new minute: roll every complete bucket below the
    /// frame's bucket. Runs after the frame's own commit on this serial queue,
    /// so every earlier minute is already committed before the sweep. Only
    /// complete past minutes are archived; the frame's own (current) minute
    /// stays directly queryable.
    private func rollUpIfNeeded(capturedAt: Date) {
        let bucket = Self.minuteBucket(for: capturedAt)
        guard bucket != lastRolledUpBucket else { return }
        lastRolledUpBucket = bucket
        database.rollupCompletedBuckets(before: bucket)
    }

    /// Fold the frame ledger accumulated by a previous run into `app_traffic`
    /// in bounded chunks on a dedicated queue, without blocking frame
    /// recording or dashboard reads. Frames of the launch minute are never
    /// touched here (they are >= `finalCutoff`); the per-minute trigger in
    /// `record` archives them as their minutes complete.
    private func startBackfill(finalCutoff: Int) {
        backfillQueue.async { [weak self] in
            guard let self else { return }
            while true {
                // Each iteration starts from the oldest un-rolled bucket, so
                // long empty gaps between data regions are crossed in a single
                // sweep instead of one empty transaction per minute.
                guard let next = self.database.oldestFinalizedBucket(below: finalCutoff) else { return }
                let high = min(next + Self.backfillChunkBuckets, finalCutoff)
                self.database.rollupCompletedBuckets(before: high)
                // After a successful sweep every finalized bucket below `high`
                // is gone, so the next oldest is nil or >= high. If it is still
                // < high the chunk rolled back — stop rather than retry forever.
                guard let after = self.database.oldestFinalizedBucket(below: finalCutoff),
                      after >= high else { return }
            }
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
        let bucketStart = Self.minuteBucket(for: capturedAt)
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

    func dayTotalTraffic(day: Int, completion: @escaping (TrafficTotal) -> Void) {
        database.dayTotalTraffic(day: day, completion: completion)
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
