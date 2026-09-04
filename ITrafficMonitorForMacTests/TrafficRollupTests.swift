import XCTest
import SQLite3
@testable import ITraffic

/// DB-level tests for the minute rollup: completed per-frame buckets are
/// aggregated into `app_traffic` and deleted without changing any query
/// result, current-minute frames stay live, and the operation is idempotent.
final class TrafficRollupTests: XCTestCase {

    private var dbURLs: [URL] = []

    override func tearDown() {
        for url in dbURLs {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        }
        dbURLs.removeAll()
        super.tearDown()
    }

    private func makeDatabase() -> (TrafficDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("itraffic-rollup-\(UUID().uuidString).sqlite3")
        dbURLs.append(url)
        return (TrafficDatabase(databaseURL: url), url)
    }

    /// One minute's aggregate, as an Equatable value for series comparisons.
    private struct MinuteTotal: Equatable {
        let bucket: Int
        let inBytes: Int
        let outBytes: Int
    }

    private func makeSample(
        id: String,
        bucketStart: Int,
        inBytes: Int,
        outBytes: Int,
        allocations: [TrafficSampleAllocation]
    ) -> TrafficSample {
        TrafficSample(
            id: id,
            capturedAtMs: Int64(bucketStart) * 1000,
            bucketStart: bucketStart,
            day: 19_675,
            hour: 3,
            rawInBytes: inBytes,
            rawOutBytes: outBytes,
            allocations: allocations
        )
    }

    private func allocation(app: String, inBytes: Int, outBytes: Int) -> TrafficSampleAllocation {
        TrafficSampleAllocation(appKey: app, displayName: app, inBytes: inBytes, outBytes: outBytes)
    }

    /// Minute-aligned epoch base well in the past (tests never collide with
    /// the live current minute).
    private var baseBucket: Int {
        TrafficRecorder.minuteBucket(for: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Sync read helpers over the existing query API (completions land on main)

    @discardableResult
    private func readTotal(
        _ database: TrafficDatabase,
        start: Int,
        end: Int
    ) -> (inBytes: Int, outBytes: Int) {
        let exp = expectation(description: "total [\(start), \(end))")
        var result: (inBytes: Int, outBytes: Int) = (0, 0)
        database.totalTraffic(start: start, end: end) { total in
            result = (total.inBytes, total.outBytes)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        return result
    }

    private func readMinuteSeries(
        _ database: TrafficDatabase,
        start: Int,
        end: Int
    ) -> [MinuteTotal] {
        let exp = expectation(description: "series [\(start), \(end))")
        var result: [MinuteTotal] = []
        database.trafficSeries(start: start, end: end, granularity: .minute) { points in
            result = points.map {
                MinuteTotal(
                    bucket: Int($0.date.timeIntervalSince1970),
                    inBytes: $0.inBytes,
                    outBytes: $0.outBytes
                )
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        return result
    }

    // MARK: - Raw helpers (row counts / seeding legacy rows / unfinalized samples)

    private func rawCount(_ sql: String, in url: URL) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return -1 }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    @discardableResult
    private func execRaw(_ sql: String, _ values: [Int64] = [], in url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        for (index, value) in values.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), value)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Tests

    func testRollupPreservesTotalsOverRange() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(
            id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50,
            allocations: [
                allocation(app: "Chrome", inBytes: 75, outBytes: 40),
                allocation(app: "Clash Verge", inBytes: 25, outBytes: 10)
            ]
        ))
        db.commitSample(makeSample(
            id: "s2", bucketStart: b0 + 60, inBytes: 200, outBytes: 100,
            allocations: [allocation(app: "Safari", inBytes: 200, outBytes: 100)]
        ))

        let beforeTotal = readTotal(db, start: b0, end: b0 + 120)
        let beforeSeries = readMinuteSeries(db, start: b0, end: b0 + 120)
        XCTAssertEqual(beforeTotal.inBytes, 300)
        XCTAssertEqual(beforeTotal.outBytes, 150)

        db.rollupCompletedBuckets(before: b0 + 120)

        let afterTotal = readTotal(db, start: b0, end: b0 + 120)
        let afterSeries = readMinuteSeries(db, start: b0, end: b0 + 120)
        XCTAssertEqual(afterTotal.inBytes, beforeTotal.inBytes)
        XCTAssertEqual(afterTotal.outBytes, beforeTotal.outBytes)
        XCTAssertEqual(afterSeries, beforeSeries)

        // Frame ledger fully folded into app_traffic: one row per (app, bucket).
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 0)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM sample_allocations;", in: url), 0)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM app_traffic;", in: url), 3)
    }

    func testRollupMovesOnlyCompletedBucketsAndKeepsCurrentMinuteLive() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(
            id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50,
            allocations: [allocation(app: "Chrome", inBytes: 100, outBytes: 50)]
        ))
        db.commitSample(makeSample(
            id: "s2", bucketStart: b0 + 60, inBytes: 200, outBytes: 100,
            allocations: [allocation(app: "Safari", inBytes: 200, outBytes: 100)]
        ))

        // Sweep only buckets strictly before b0+60 → s2's "current" minute stays.
        db.rollupCompletedBuckets(before: b0 + 60)

        let liveTotal = readTotal(db, start: b0 + 60, end: b0 + 120)
        XCTAssertEqual(liveTotal.inBytes, 200)
        XCTAssertEqual(liveTotal.outBytes, 100)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM app_traffic;", in: url), 1)

        // Rolling the rest preserves the whole-range totals.
        db.rollupCompletedBuckets(before: b0 + 120)
        let whole = readTotal(db, start: b0, end: b0 + 120)
        XCTAssertEqual(whole.inBytes, 300)
        XCTAssertEqual(whole.outBytes, 150)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 0)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM app_traffic;", in: url), 2)
    }

    func testRollupSkipsNonFinalizedSamples() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket

        // Simulate a crash-leftover row: sample present but never finalized.
        XCTAssertTrue(execRaw(
            "INSERT INTO traffic_samples(sample_id,captured_at_ms,bucket_start,day,hour,raw_in_bytes,raw_out_bytes,finalized) VALUES('uf1',?,?,?,?,?,?,0);",
            [Int64(b0) * 1000, Int64(b0), 19_675, 3, 500, 250], in: url
        ))
        XCTAssertTrue(execRaw(
            "INSERT INTO sample_allocations(sample_id,app_key,in_bytes,out_bytes) VALUES('uf1','Chrome',500,250);",
            in: url
        ))

        db.rollupCompletedBuckets(before: b0 + 60)

        // Unfinalized rows are invisible to the view and never swept.
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples WHERE sample_id='uf1';", in: url), 1)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM sample_allocations WHERE sample_id='uf1';", in: url), 1)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM app_traffic WHERE app_key='Chrome' AND bucket_start=\(b0);", in: url), 0)
        let total = readTotal(db, start: b0, end: b0 + 60)
        XCTAssertEqual(total.inBytes, 0)
        XCTAssertEqual(total.outBytes, 0)

        // A finalized sample in the same bucket is folded normally.
        db.commitSample(makeSample(
            id: "ok1", bucketStart: b0, inBytes: 100, outBytes: 50,
            allocations: [allocation(app: "Chrome", inBytes: 100, outBytes: 50)]
        ))
        db.rollupCompletedBuckets(before: b0 + 60)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples WHERE sample_id='uf1';", in: url), 1)
        XCTAssertEqual(readTotal(db, start: b0, end: b0 + 60).inBytes, 100)
    }

    func testRollupIsIdempotentOnDoubleRun() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(
            id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50,
            allocations: [allocation(app: "Chrome", inBytes: 100, outBytes: 50)]
        ))

        db.rollupCompletedBuckets(before: b0 + 60)
        db.rollupCompletedBuckets(before: b0 + 120)

        let total = readTotal(db, start: b0, end: b0 + 60)
        XCTAssertEqual(total.inBytes, 100)
        XCTAssertEqual(total.outBytes, 50)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM app_traffic;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT SUM(in_bytes) FROM app_traffic;", in: url), 100)
    }

    func testRollupMergesIntoPreexistingAppTrafficRow() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket

        // Legacy minute row that predates the frame ledger.
        XCTAssertTrue(execRaw(
            "INSERT INTO app_traffic(app_key,bucket_start,day,hour,in_bytes,out_bytes,sample_count) VALUES('Chrome',?,19_675,3,500,100,3);",
            [Int64(b0)], in: url
        ))

        db.commitSample(makeSample(
            id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50,
            allocations: [allocation(app: "Chrome", inBytes: 100, outBytes: 50)]
        ))
        db.rollupCompletedBuckets(before: b0 + 60)

        let total = readTotal(db, start: b0, end: b0 + 60)
        XCTAssertEqual(total.inBytes, 600)
        XCTAssertEqual(total.outBytes, 150)
        XCTAssertEqual(rawCount(
            "SELECT COUNT(*) FROM app_traffic WHERE app_key='Chrome' AND bucket_start=\(b0);", in: url
        ), 1)
        XCTAssertEqual(rawCount("SELECT SUM(in_bytes) FROM app_traffic;", in: url), 600)
    }

    func testChunkedRollupMatchesOneShot() {
        let b0 = baseBucket

        // Two identical databases.
        let (chunked, _) = makeDatabase()
        let (oneShot, _) = makeDatabase()
        for (database, prefix) in [(chunked, "c"), (oneShot, "o")] {
            database.commitSample(makeSample(
                id: prefix + "a", bucketStart: b0, inBytes: 100, outBytes: 50,
                allocations: [allocation(app: "Chrome", inBytes: 100, outBytes: 50)]
            ))
            database.commitSample(makeSample(
                id: prefix + "b", bucketStart: b0 + 60, inBytes: 200, outBytes: 100,
                allocations: [allocation(app: "Safari", inBytes: 200, outBytes: 100)]
            ))
            database.commitSample(makeSample(
                id: prefix + "c", bucketStart: b0 + 120, inBytes: 400, outBytes: 200,
                allocations: [allocation(app: "Chrome", inBytes: 400, outBytes: 200)]
            ))
        }

        // Simulate the startup backfill loop: one 60s chunk per sweep.
        let finalCutoff = b0 + 180
        while true {
            guard let next = chunked.oldestFinalizedBucket(below: finalCutoff) else { break }
            let high = min(next + 60, finalCutoff)
            chunked.rollupCompletedBuckets(before: high)
        }
        oneShot.rollupCompletedBuckets(before: finalCutoff)

        XCTAssertEqual(
            readTotal(chunked, start: b0, end: finalCutoff).inBytes,
            readTotal(oneShot, start: b0, end: finalCutoff).inBytes
        )
        XCTAssertEqual(
            readTotal(chunked, start: b0, end: finalCutoff).outBytes,
            readTotal(oneShot, start: b0, end: finalCutoff).outBytes
        )
        XCTAssertEqual(
            readMinuteSeries(chunked, start: b0, end: finalCutoff),
            readMinuteSeries(oneShot, start: b0, end: finalCutoff)
        )
    }

    func testRecorderRollsUpWhenMinuteChanges() {
        let (_, url) = makeDatabase()
        let b0 = TrafficRecorder.minuteBucket(for: Date())
        let recorder = TrafficRecorder(databaseURL: url)

        // Two frames in the launch minute. PIDs are high fake values so the
        // app-key resolution falls back to the process name (no real process).
        recorder.record(
            entities: [ProcessEntity(pid: 90_000, name: "Chrome", inBytes: 100, outBytes: 50)],
            sampleID: "r1",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(b0 + 1))
        )
        recorder.record(
            entities: [ProcessEntity(pid: 90_001, name: "Safari", inBytes: 200, outBytes: 100)],
            sampleID: "r2",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(b0 + 2))
        )
        recorder.flush()

        let exp1 = expectation(description: "total after minute one")
        var totalAfterMinuteOne = (0, 0)
        recorder.totalTraffic(start: b0, end: b0 + 60) { total in
            totalAfterMinuteOne = (total.inBytes, total.outBytes)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2)
        XCTAssertEqual(totalAfterMinuteOne.0, 300)
        XCTAssertEqual(totalAfterMinuteOne.1, 150)

        // First frame of the next minute triggers the rollup of the previous one.
        recorder.record(
            entities: [ProcessEntity(pid: 90_000, name: "Chrome", inBytes: 30, outBytes: 10)],
            sampleID: "r3",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(b0 + 61))
        )
        recorder.flush()

        let exp2 = expectation(description: "total across minutes")
        var totalAcross = (0, 0)
        recorder.totalTraffic(start: b0, end: b0 + 120) { total in
            totalAcross = (total.inBytes, total.outBytes)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2)
        XCTAssertEqual(totalAcross.0, 330)
        XCTAssertEqual(totalAcross.1, 160)

        // Previous minute folded (1 app_traffic row per app bucket), current
        // minute's frame still in the ledger.
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM app_traffic;", in: url), 2)
    }
}
