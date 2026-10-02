import XCTest
import SQLite3
@testable import ITraffic

/// DB-level tests for total-only accounting: completed per-frame buckets are
/// aggregated into `traffic_totals` and deleted without changing any query
/// result, current-minute frames stay live, the operation is idempotent, and
/// the one-time migration from the legacy per-app schema folds history.
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
        outBytes: Int
    ) -> TrafficSample {
        TrafficSample(
            id: id,
            capturedAtMs: Int64(bucketStart) * 1000,
            bucketStart: bucketStart,
            day: 19_675,
            hour: 3,
            rawInBytes: inBytes,
            rawOutBytes: outBytes
        )
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

    // MARK: - Rollup

    func testRollupPreservesTotalsOverRange() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50))
        db.commitSample(makeSample(id: "s2", bucketStart: b0 + 60, inBytes: 200, outBytes: 100))

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

        // Frame ledger fully folded into traffic_totals: one row per bucket.
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 0)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 2)
    }

    func testRollupMovesOnlyCompletedBucketsAndKeepsCurrentMinuteLive() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50))
        db.commitSample(makeSample(id: "s2", bucketStart: b0 + 60, inBytes: 200, outBytes: 100))

        // Sweep only buckets strictly before b0+60 → s2's "current" minute stays.
        db.rollupCompletedBuckets(before: b0 + 60)

        let liveTotal = readTotal(db, start: b0 + 60, end: b0 + 120)
        XCTAssertEqual(liveTotal.inBytes, 200)
        XCTAssertEqual(liveTotal.outBytes, 100)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 1)

        // Rolling the rest preserves the whole-range totals.
        db.rollupCompletedBuckets(before: b0 + 120)
        let whole = readTotal(db, start: b0, end: b0 + 120)
        XCTAssertEqual(whole.inBytes, 300)
        XCTAssertEqual(whole.outBytes, 150)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 0)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 2)
    }

    func testRollupSkipsNonFinalizedSamples() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket

        // Simulate a crash-leftover row: sample present but never finalized.
        XCTAssertTrue(execRaw(
            "INSERT INTO traffic_samples(sample_id,captured_at_ms,bucket_start,day,hour,raw_in_bytes,raw_out_bytes,finalized) VALUES('uf1',?,?,?,?,?,?,0);",
            [Int64(b0) * 1000, Int64(b0), 19_675, 3, 500, 250], in: url
        ))

        db.rollupCompletedBuckets(before: b0 + 60)

        // Unfinalized rows are invisible to the view and never swept.
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples WHERE sample_id='uf1';", in: url), 1)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 0)
        let total = readTotal(db, start: b0, end: b0 + 60)
        XCTAssertEqual(total.inBytes, 0)
        XCTAssertEqual(total.outBytes, 0)

        // A finalized sample in the same bucket is folded normally.
        db.commitSample(makeSample(id: "ok1", bucketStart: b0, inBytes: 100, outBytes: 50))
        db.rollupCompletedBuckets(before: b0 + 60)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples WHERE sample_id='uf1';", in: url), 1)
        XCTAssertEqual(readTotal(db, start: b0, end: b0 + 60).inBytes, 100)
    }

    func testRollupIsIdempotentOnDoubleRun() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50))

        db.rollupCompletedBuckets(before: b0 + 60)
        db.rollupCompletedBuckets(before: b0 + 120)

        let total = readTotal(db, start: b0, end: b0 + 60)
        XCTAssertEqual(total.inBytes, 100)
        XCTAssertEqual(total.outBytes, 50)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT SUM(in_bytes) FROM traffic_totals;", in: url), 100)
    }

    func testReplayAfterArchiveDoesNotDoubleCount() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        let sample = makeSample(id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50)

        db.commitSample(sample)
        db.rollupCompletedBuckets(before: b0 + 60)
        XCTAssertEqual(readTotal(db, start: b0, end: b0 + 60).inBytes, 100)

        // Replay the same frame after its ledger row was rolled up and
        // deleted: must remain a no-op (tombstoned sample id).
        db.commitSample(sample)
        db.rollupCompletedBuckets(before: b0 + 60)

        let total = readTotal(db, start: b0, end: b0 + 60)
        XCTAssertEqual(total.inBytes, 100)
        XCTAssertEqual(total.outBytes, 50)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 0)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT SUM(in_bytes) FROM traffic_totals;", in: url), 100)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM archived_samples WHERE sample_id='s1';", in: url), 1)
    }

    func testExpiredArchiveTombstonesArePruned() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(id: "expired", bucketStart: b0, inBytes: 100, outBytes: 50))
        db.rollupCompletedBuckets(before: b0 + 60)

        let expiredAt = Int64(Date().timeIntervalSince1970) - 10 * 24 * 60 * 60
        XCTAssertTrue(execRaw(
            "UPDATE archived_samples SET archived_at = ? WHERE sample_id='expired';",
            [expiredAt], in: url
        ))

        // A later successful sweep compacts old deduplication metadata while
        // retaining recent tombstones for delayed frame retries.
        XCTAssertTrue(db.rollupCompletedBuckets(before: b0 + 120))
        XCTAssertEqual(rawCount(
            "SELECT COUNT(*) FROM archived_samples WHERE sample_id='expired';", in: url
        ), 0)
    }

    func testFailedRollupRollsBackAndLeavesDatabaseUsable() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50))

        // Force a mid-transaction failure: dropping the tombstone table makes
        // the archive step (and the prune step) fail to prepare.
        XCTAssertTrue(execRaw("DROP TABLE archived_samples;", in: url))
        XCTAssertFalse(db.rollupCompletedBuckets(before: b0 + 60))

        // The failed sweep must have rolled back completely: the frame rows
        // and query totals are untouched.
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 0)
        XCTAssertEqual(readTotal(db, start: b0, end: b0 + 60).inBytes, 100)

        // Restore the tombstone table, then prove the connection still works
        // for both new commits and a successful rollup of the same bucket.
        XCTAssertTrue(execRaw(
            "CREATE TABLE archived_samples(sample_id TEXT PRIMARY KEY, archived_at INTEGER NOT NULL DEFAULT 0);",
            in: url
        ))
        db.commitSample(makeSample(id: "s2", bucketStart: b0, inBytes: 50, outBytes: 25))
        XCTAssertTrue(db.rollupCompletedBuckets(before: b0 + 60))

        let total = readTotal(db, start: b0, end: b0 + 60)
        XCTAssertEqual(total.inBytes, 150)
        XCTAssertEqual(total.outBytes, 75)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 0)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM archived_samples;", in: url), 2)
    }

    func testRollupMergesIntoPreexistingTotalRow() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket

        // Pre-existing bucket that predates the frame ledger (e.g. folded from
        // the legacy schema). Day/hour are bound parameters.
        XCTAssertTrue(execRaw(
            "INSERT INTO traffic_totals(bucket_start,day,hour,in_bytes,out_bytes,sample_count) VALUES(?,?,?,500,100,3);",
            [Int64(b0), 19_675, 3], in: url
        ))

        db.commitSample(makeSample(id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50))
        db.rollupCompletedBuckets(before: b0 + 60)

        let total = readTotal(db, start: b0, end: b0 + 60)
        XCTAssertEqual(total.inBytes, 600)
        XCTAssertEqual(total.outBytes, 150)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals WHERE bucket_start=\(b0);", in: url), 1)
        XCTAssertEqual(rawCount("SELECT SUM(in_bytes) FROM traffic_totals;", in: url), 600)
    }

    func testChunkedRollupMatchesOneShot() {
        let b0 = baseBucket

        // Two identical databases.
        let (chunked, _) = makeDatabase()
        let (oneShot, _) = makeDatabase()
        for (database, prefix) in [(chunked, "c"), (oneShot, "o")] {
            database.commitSample(makeSample(id: prefix + "a", bucketStart: b0, inBytes: 100, outBytes: 50))
            database.commitSample(makeSample(id: prefix + "b", bucketStart: b0 + 60, inBytes: 200, outBytes: 100))
            database.commitSample(makeSample(id: prefix + "c", bucketStart: b0 + 120, inBytes: 400, outBytes: 200))
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

        // Two frames in the launch minute.
        recorder.record(
            sampleID: "r1",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(b0 + 1)),
            rawInBytes: 100,
            rawOutBytes: 50
        )
        recorder.record(
            sampleID: "r2",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(b0 + 2)),
            rawInBytes: 200,
            rawOutBytes: 100
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
            sampleID: "r3",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(b0 + 61)),
            rawInBytes: 30,
            rawOutBytes: 10
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

        // Previous minute folded; current minute's frame still in the ledger.
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_samples;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 1)
    }

    // MARK: - One-time per-app-removal migration

    /// A database at the legacy schema (user_version 0, `app_traffic` present)
    /// folds its per-app buckets into `traffic_totals`, drops the per-app
    /// tables and lands on the current version, preserving total bytes.
    func testPerAppRemovalMigrationFoldsLegacyHistory() {
        let (_, url) = makeDatabase()
        createLegacyPerAppSchema(in: url)
        execRaw("INSERT INTO app_traffic VALUES('Chrome', 1000, 100, 1, 300, 100, 3);", in: url)
        execRaw("INSERT INTO app_traffic VALUES('Clash Verge', 1000, 100, 1, 50, -20, 1);", in: url)
        execRaw("INSERT INTO app_traffic VALUES('Safari', 1060, 100, 1, 200, 80, 2);", in: url)
        execRaw("PRAGMA user_version = 0;", in: url)

        let migrated = TrafficDatabase(databaseURL: url)

        XCTAssertEqual(rawCount("PRAGMA user_version;", in: url), 2)
        XCTAssertEqual(rawCount(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('app_traffic','sample_allocations','apps');",
            in: url), 0)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 2)
        // MAX(0, ·) folds the legacy negative away: bucket 1000 = 300+50 in, 100+0 out.
        XCTAssertEqual(rawCount("SELECT in_bytes FROM traffic_totals WHERE bucket_start=1000;", in: url), 350)
        XCTAssertEqual(rawCount("SELECT out_bytes FROM traffic_totals WHERE bucket_start=1000;", in: url), 100)
        XCTAssertEqual(rawCount("SELECT in_bytes FROM traffic_totals WHERE bucket_start=1060;", in: url), 200)

        let total = readTotal(migrated, start: 0, end: 2000)
        XCTAssertEqual(total.inBytes, 550)
        XCTAssertEqual(total.outBytes, 180)
    }

    /// The fold is guarded per bucket, so a bucket already present in
    /// `traffic_totals` is never counted twice.
    func testPerAppRemovalFoldIsIdempotentPerBucket() {
        let (_, url) = makeDatabase()
        createLegacyPerAppSchema(in: url)
        execRaw("INSERT INTO app_traffic VALUES('Chrome', 1000, 100, 1, 300, 100, 3);", in: url)
        execRaw("INSERT INTO traffic_totals(bucket_start,day,hour,in_bytes,out_bytes,sample_count) VALUES(1000,100,1,999,999,9);", in: url)
        execRaw("PRAGMA user_version = 0;", in: url)

        let migrated = TrafficDatabase(databaseURL: url)
        _ = migrated

        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 1)
        XCTAssertEqual(rawCount("SELECT in_bytes FROM traffic_totals WHERE bucket_start=1000;", in: url), 999)
        XCTAssertEqual(rawCount(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='app_traffic';", in: url), 0)
        XCTAssertEqual(rawCount("PRAGMA user_version;", in: url), 2)
    }

    /// A fresh database is created directly on the total-only schema.
    func testFreshDatabaseIsTotalOnlyAtCurrentVersion() {
        let (db, url) = makeDatabase()
        _ = db
        XCTAssertEqual(rawCount("PRAGMA user_version;", in: url), 2)
        XCTAssertEqual(rawCount(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='traffic_totals';", in: url), 1)
        XCTAssertEqual(rawCount(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='app_traffic';", in: url), 0)
        XCTAssertEqual(rawCount(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='view' AND name='accounted_traffic';", in: url), 1)
    }

    /// Reopening an already-migrated database is a no-op.
    func testReopeningCurrentDatabaseKeepsVersionAndData() {
        let (db, url) = makeDatabase()
        let b0 = baseBucket
        db.commitSample(makeSample(id: "s1", bucketStart: b0, inBytes: 100, outBytes: 50))
        db.rollupCompletedBuckets(before: b0 + 60)

        let reopened = TrafficDatabase(databaseURL: url)
        XCTAssertEqual(rawCount("PRAGMA user_version;", in: url), 2)
        XCTAssertEqual(rawCount("SELECT COUNT(*) FROM traffic_totals;", in: url), 1)
        XCTAssertEqual(readTotal(reopened, start: b0, end: b0 + 60).inBytes, 100)
    }

    // MARK: - Test-host isolation

    /// The default (no-URL) database must never be the production one under
    /// tests: a freshly isolated test database has no history, while the real
    /// database holds terabytes. This fails loudly if the test host ever falls
    /// back to the production path.
    func testDefaultDatabaseIsIsolatedFromProductionUnderTests() {
        let total = readTotal(TrafficDatabase(), start: 0, end: Int.max)
        XCTAssertEqual(total.inBytes, 0)
        XCTAssertEqual(total.outBytes, 0)
    }

    // MARK: - Helpers

    /// Recreate the pre-migration per-app schema so the migration path can be
    /// exercised on a database that already has the current total-only tables.
    private func createLegacyPerAppSchema(in url: URL) {
        execRaw("""
        CREATE TABLE app_traffic (
          app_key TEXT NOT NULL, bucket_start INTEGER NOT NULL, day INTEGER NOT NULL, hour INTEGER NOT NULL,
          in_bytes INTEGER NOT NULL DEFAULT 0, out_bytes INTEGER NOT NULL DEFAULT 0,
          sample_count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(app_key,bucket_start));
        """, in: url)
        execRaw("""
        CREATE TABLE sample_allocations (
          sample_id TEXT NOT NULL, app_key TEXT NOT NULL,
          in_bytes INTEGER NOT NULL DEFAULT 0, out_bytes INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(sample_id,app_key));
        """, in: url)
        execRaw("""
        CREATE TABLE apps (app_key TEXT PRIMARY KEY, display_name TEXT NOT NULL, last_seen INTEGER NOT NULL);
        """, in: url)
    }
}
