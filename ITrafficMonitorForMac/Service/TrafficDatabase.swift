//
//  TrafficDatabase.swift
//  ITrafficMonitorForMac
//
//  Thin wrapper around the system sqlite3 C API. All access happens on
//  a dedicated serial queue (`dbQueue`) so the recorder and dashboard
//  queries never race on the connection.
//

import Foundation
import SQLite3

/// SQLITE_TRANSIENT is a C macro; Swift exposes it as this unsafe bitcast.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DayTrafficRow {
    let day: Int      // local days since 1970-01-01
    let inBytes: Int
    let outBytes: Int
}

struct TrafficTotal {
    let inBytes: Int
    let outBytes: Int
}

enum ExportGranularity: CaseIterable {
    case minute, hour, day, month

    var label: String {
        switch self {
        case .minute: return "Minute"
        case .hour: return "Hour"
        case .day: return "Day"
        case .month: return "Month"
        }
    }
}

struct ExportTrafficRow {
    let period: Date
    let inBytes: Int
    let outBytes: Int
}

/// One cell in the day-granularity calendar heatmap (last 365 days).
struct CalendarDayCell: Hashable {
    let day: Int
    let totalBytes: Int
}

/// One bar in the horizontal usage bar chart: total traffic for a
/// day / month / quarter / year period.
struct BarPeriodPoint: Identifiable {
    let period: Date
    let label: String   // language-neutral category label, e.g. "2026-08", "2026-Q3"
    let totalBytes: Int
    var id: String { label }
}

enum TimeSeriesGranularity {
    case minute, hour, day
}

struct TrafficSeriesPoint: Identifiable {
    let date: Date
    let inBytes: Int
    let outBytes: Int
    var id: Date { date }
}

/// SQLite has no `start of hour` modifier. Group by a local calendar-hour
/// key and use the earliest bucket timestamp as the chart point's date.
let hourSeriesSQL = """
SELECT MIN(bucket_start) AS hour_start,
       SUM(in_bytes), SUM(out_bytes)
FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ?
GROUP BY strftime('%Y-%m-%d %H', bucket_start, 'unixepoch', 'localtime')
ORDER BY hour_start;
"""

/// How long a tombstoned sample id is retained in `archived_samples`. A frame
/// can only be replayed within the session/restart window that recorded it, so
/// 7 days bounds the table (~302k rows) while covering every replay that can
/// actually occur. `rollupPruneArchivedSamplesSQL` removes older rows.
private let archivedSampleRetentionSeconds = 7 * 24 * 60 * 60

/// Rollup sweep 1/4: aggregate every finalized sample below a cutoff into the
/// minute-bucket `traffic_totals` table, merging additively with any bucket
/// that already exists (e.g. from a legacy fold or a replay at the boundary).
///
/// `MIN(s.day)/MIN(s.hour)` are safe because a `bucket_start` is a whole
/// minute, so all samples inside it map to the same local (day, hour).
private let rollupInsertSQL = """
INSERT INTO traffic_totals(bucket_start,day,hour,in_bytes,out_bytes,sample_count)
SELECT s.bucket_start,
       MIN(s.day), MIN(s.hour),
       SUM(s.raw_in_bytes), SUM(s.raw_out_bytes),
       COUNT(*)
FROM traffic_samples AS s
WHERE s.finalized = 1 AND s.bucket_start < ?
GROUP BY s.bucket_start
ON CONFLICT(bucket_start) DO UPDATE SET
  in_bytes     = traffic_totals.in_bytes     + excluded.in_bytes,
  out_bytes    = traffic_totals.out_bytes    + excluded.out_bytes,
  sample_count = traffic_totals.sample_count + excluded.sample_count;
"""

/// Rollup sweep 2/4: tombstone the swept sample ids so a replay of an
/// already-archived frame stays a no-op (commitSample idempotency). Without
/// this, deleting the frame row would also delete the dedup key.
private let rollupArchiveSamplesSQL = """
INSERT INTO archived_samples(sample_id, archived_at)
SELECT sample_id, CAST(strftime('%s','now') AS INTEGER) FROM traffic_samples
WHERE finalized = 1 AND bucket_start < ?
ON CONFLICT(sample_id) DO NOTHING;
"""

/// Rollup sweep 3/4: remove deduplication metadata outside the retry window.
/// This bounds the tombstone table instead of moving the unbounded growth from
/// the frame ledger into `archived_samples`.
private let rollupPruneArchivedSamplesSQL = """
DELETE FROM archived_samples
WHERE archived_at < CAST(strftime('%s','now') AS INTEGER) - \(archivedSampleRetentionSeconds);
"""

/// Rollup sweep 4/4: delete the swept samples.
private let rollupDeleteSamplesSQL = """
DELETE FROM traffic_samples
WHERE finalized = 1 AND bucket_start < ?;
"""

struct TrafficSample: Equatable {
    let id: String
    let capturedAtMs: Int64
    let bucketStart: Int
    let day: Int
    let hour: Int
    let rawInBytes: Int
    let rawOutBytes: Int
}

final class TrafficDatabase {

    private let dbQueue = DispatchQueue(label: "traffic-db", qos: .utility)
    private let databaseURL: URL?
    private var db: OpaquePointer?
    /// Resolved path of the open database. Used by the one-time per-app-removal
    /// backup so it can snapshot the exact file the connection is using.
    private var databasePath: String?

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
        dbQueue.sync {
            self.open()
        }
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Lifecycle

    private func open() {
        let dbPath: String
        if let databaseURL {
            dbPath = databaseURL.path
        } else if AppEnvironment.isRunningTests {
            // Hard guarantee: never read or write the production database from a
            // test host, even if something constructs the default store.
            dbPath = Self.isolatedTestDatabaseURL().path
        } else {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ITraffic", isDirectory: true)
            try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            dbPath = appSupport.appendingPathComponent("traffic.sqlite3").path
        }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            print("[TrafficDatabase] open failed: \(msg)")
            return
        }
        self.databasePath = dbPath
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        migrate()
    }

    /// Throwaway database for a test host, scoped to the process so parallel
    /// runs never share state. Used only when no explicit URL is supplied and
    /// `AppEnvironment.isRunningTests` is set.
    private static func isolatedTestDatabaseURL() -> URL {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("itraffic-testhost-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("traffic.sqlite3")
    }

    private func migrate() {
        createCoreTables()
        migrateArchivedSamplesTimestamp()
        ensureAccountedTrafficView()
        migratePerAppRemovalIfNeeded()
    }

    /// Create the total-only tables and indexes. Idempotent; runs on every
    /// launch. The `accounted_traffic` view is created separately so a legacy
    /// app-keyed view is replaced rather than left in place.
    @discardableResult
    private func createCoreTables() -> Bool {
        guard let db else { return false }
        let schema = """
        CREATE TABLE IF NOT EXISTS traffic_totals (
          bucket_start INTEGER PRIMARY KEY,
          day          INTEGER NOT NULL,
          hour         INTEGER NOT NULL,
          in_bytes     INTEGER NOT NULL DEFAULT 0,
          out_bytes    INTEGER NOT NULL DEFAULT 0,
          sample_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS traffic_samples (
          sample_id       TEXT PRIMARY KEY,
          captured_at_ms  INTEGER NOT NULL,
          bucket_start    INTEGER NOT NULL,
          day             INTEGER NOT NULL,
          hour            INTEGER NOT NULL,
          raw_in_bytes    INTEGER NOT NULL,
          raw_out_bytes   INTEGER NOT NULL,
          finalized       INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_traffic_samples_bucket ON traffic_samples(bucket_start);
        CREATE TABLE IF NOT EXISTS archived_samples (
          sample_id   TEXT PRIMARY KEY,
          archived_at INTEGER NOT NULL DEFAULT 0
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] schema creation failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    /// (Re)create the total-only `accounted_traffic` view: rolled minute
    /// buckets from `traffic_totals`, unioned with the still-live frame ledger.
    /// The two arms are disjoint by the rollup cutoff, so no bucket is counted
    /// twice. `DROP` first because SQLite has no `CREATE VIEW IF NOT EXISTS`
    /// replacement, and a legacy database already has an app-keyed definition.
    private func ensureAccountedTrafficView() {
        guard let db else { return }
        let sql = """
        DROP VIEW IF EXISTS accounted_traffic;
        CREATE VIEW accounted_traffic AS
          SELECT bucket_start, day, hour, in_bytes, out_bytes FROM traffic_totals
          UNION ALL
          SELECT bucket_start, day, hour, raw_in_bytes, raw_out_bytes
          FROM traffic_samples WHERE finalized = 1;
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("[TrafficDatabase] accounted_traffic view creation failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// `PRAGMA user_version` for the total-only schema. Databases at 1 (the
    /// retired dirty-data cleanup) or 0 (older) migrate to it exactly once.
    private static let currentSchemaVersion: Int32 = 2

    /// One-time migration from the per-app schema to the total-only schema,
    /// gated by `PRAGMA user_version`. The legacy history is folded losslessly
    /// (summed over apps per bucket) before the per-app tables are dropped.
    /// The fold, the drops and the version bump share one transaction, so a
    /// failure leaves the old schema usable and retries on the next launch.
    private func migratePerAppRemovalIfNeeded() {
        guard let db else { return }
        let hasLegacy = legacyPerAppTablesPresent()
        if !hasLegacy, userVersion() >= Self.currentSchemaVersion {
            return
        }

        // One-time safety snapshot before the destructive fold. Only when a
        // legacy database is actually present, and never under tests.
        if hasLegacy, !AppEnvironment.isRunningTests {
            backupBeforePerAppRemoval()
        }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] per-app removal BEGIN failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        var ok = createCoreTables()
        if hasLegacy {
            ok = ok && foldAppTrafficIntoTotalsLocked()
        }
        ok = ok && dropLegacyPerAppObjectsLocked()
        let bump = "PRAGMA user_version = \(Self.currentSchemaVersion);"
        if ok, sqlite3_exec(db, bump, nil, nil, nil) == SQLITE_OK {
            _ = commitTransaction(db, failureMessage: "[TrafficDatabase] per-app removal COMMIT failed")
        } else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            print("[TrafficDatabase] per-app removal rolled back: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// True when this database still has the per-app `app_traffic` table, i.e.
    /// it predates the total-only schema.
    private func legacyPerAppTablesPresent() -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='app_traffic' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Sum every per-app bucket into the total-only table. `MAX(0, ·)` (scalar
    /// form) absorbs the retired negative-counter clamp, and the `NOT EXISTS`
    /// guard makes the fold idempotent per bucket so a re-run can never double
    /// count. Runs inside the caller's transaction.
    private func foldAppTrafficIntoTotalsLocked() -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT INTO traffic_totals(bucket_start,day,hour,in_bytes,out_bytes,sample_count)
        SELECT a.bucket_start, MIN(a.day), MIN(a.hour),
               SUM(MAX(0, a.in_bytes)), SUM(MAX(0, a.out_bytes)), SUM(a.sample_count)
        FROM app_traffic AS a
        WHERE NOT EXISTS (
          SELECT 1 FROM traffic_totals AS t WHERE t.bucket_start = a.bucket_start
        )
        GROUP BY a.bucket_start;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] per-app fold failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    /// Drop the per-app storage now that its totals have been folded. Runs
    /// inside the caller's transaction.
    private func dropLegacyPerAppObjectsLocked() -> Bool {
        guard let db else { return false }
        let sql = """
        DROP TABLE IF EXISTS sample_allocations;
        DROP TABLE IF EXISTS app_traffic;
        DROP TABLE IF EXISTS apps;
        DROP INDEX IF EXISTS idx_traffic_bucket;
        DROP INDEX IF EXISTS idx_sample_allocations_app;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] legacy per-app drop failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    /// One-time snapshot of the database before the destructive per-app fold.
    /// `VACUUM INTO` reads through the open WAL connection, so the snapshot is
    /// a consistent single file that includes uncheckpointed frames. A failure
    /// is logged and ignored: the migration transaction is the primary safety
    /// net (fold + drops + version bump roll back together).
    private func backupBeforePerAppRemoval() {
        guard let db, let databasePath else { return }
        let backupPath = "\(databasePath).pre-perapp-removal-\(Int(Date().timeIntervalSince1970)).bak"
        let escaped = backupPath.replacingOccurrences(of: "'", with: "''")
        if sqlite3_exec(db, "VACUUM INTO '\(escaped)';", nil, nil, nil) == SQLITE_OK {
            print("[TrafficDatabase] per-app removal backup written to \(backupPath)")
        } else {
            print("[TrafficDatabase] per-app removal backup skipped: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Add the archive timestamp to databases created by the first tombstone
    /// migration. Existing rows are treated as recently archived so a schema
    /// upgrade does not immediately discard their replay protection.
    private func migrateArchivedSamplesTimestamp() {
        guard let db else { return }

        var stmt: OpaquePointer?
        let tableInfo = "PRAGMA table_info(archived_samples);"
        guard sqlite3_prepare_v2(db, tableInfo, -1, &stmt, nil) == SQLITE_OK else {
            print("[TrafficDatabase] archived_samples schema inspection failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        var hasArchivedAt = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(stmt, 1)) == "archived_at" {
                hasArchivedAt = true
                break
            }
        }
        sqlite3_finalize(stmt)

        if !hasArchivedAt {
            let alter = "ALTER TABLE archived_samples ADD COLUMN archived_at INTEGER NOT NULL DEFAULT 0;"
            guard sqlite3_exec(db, alter, nil, nil, nil) == SQLITE_OK else {
                print("[TrafficDatabase] archived_samples timestamp migration failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            let backfill = "UPDATE archived_samples SET archived_at = CAST(strftime('%s','now') AS INTEGER) WHERE archived_at = 0;"
            guard sqlite3_exec(db, backfill, nil, nil, nil) == SQLITE_OK else {
                print("[TrafficDatabase] archived_samples timestamp backfill failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
        }

        let index = "CREATE INDEX IF NOT EXISTS idx_archived_samples_at ON archived_samples(archived_at);"
        if sqlite3_exec(db, index, nil, nil, nil) != SQLITE_OK {
            print("[TrafficDatabase] archived_samples timestamp index migration failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Read `PRAGMA user_version` (0 for a database this code has never
    /// cleaned). Runs on `dbQueue`.
    private func userVersion() -> Int32 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: - Write

    /// Commit one finalized capture sample atomically. The sample identifier
    /// is the idempotency key: a retry of an already finalized sample is a
    /// no-op, so replaying a frame cannot inflate history. Totals are
    /// structural: `traffic_samples.raw_*` is the only byte source.
    func commitSample(_ sample: TrafficSample) {
        guard sample.rawInBytes >= 0, sample.rawOutBytes >= 0 else {
            print("[TrafficDatabase] rejected negative sample \(sample.id)")
            return
        }
        dbQueue.sync {
            commitSampleLocked(sample)
        }
    }

    // MARK: - Rollup (frame ledger → minute buckets)

    /// Roll every finalized sample with `bucket_start < beforeBucket` up into
    /// `traffic_totals` and delete the frame rows, in one transaction. Returns
    /// false when the sweep could not be committed (BEGIN / step / COMMIT
    /// failure); callers should retry later.
    ///
    /// The cutoff is minute-aligned, so a sweep never splits a minute bucket.
    /// Idempotent: a swept row is deleted in the same transaction that
    /// aggregates it, and its sample id is tombstoned in `archived_samples`
    /// so a replayed frame can never double-count. Repeated calls with
    /// non-decreasing cutoffs are safe. Runs synchronously on `dbQueue`;
    /// never call this from a block already executing on `dbQueue`.
    @discardableResult
    func rollupCompletedBuckets(before beforeBucket: Int) -> Bool {
        dbQueue.sync {
            rollupCompletedBucketsLocked(before: beforeBucket)
        }
    }

    /// Smallest finalized bucket below `beforeBucket`, or nil when nothing is
    /// pending. Used by the startup backfill loop to find the first frame
    /// bucket without scanning the whole epoch.
    func oldestFinalizedBucket(below beforeBucket: Int) -> Int? {
        dbQueue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            let sql = "SELECT MIN(bucket_start) FROM traffic_samples WHERE finalized = 1 AND bucket_start < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func rollupCompletedBucketsLocked(before beforeBucket: Int) -> Bool {
        guard let db else { return false }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] rollup BEGIN failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }

        var failed = false
        if !execRollupStatement(db, sql: rollupInsertSQL, before: beforeBucket) { failed = true }
        if !execRollupStatement(db, sql: rollupArchiveSamplesSQL, before: beforeBucket) { failed = true }
        if !execRollupStatementWithoutBindings(db, sql: rollupPruneArchivedSamplesSQL) { failed = true }
        if !execRollupStatement(db, sql: rollupDeleteSamplesSQL, before: beforeBucket) { failed = true }

        if failed {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            print("[TrafficDatabase] rolled back rollup before=\(beforeBucket): \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        guard commitTransaction(db, failureMessage: "[TrafficDatabase] rollup COMMIT failed before=\(beforeBucket)") else {
            return false
        }
        return true
    }

    /// Run one rollup statement with the cutoff bound to its single `?`.
    private func execRollupStatement(_ db: OpaquePointer?, sql: String, before: Int) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(before))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Execute a rollup statement that has no bound values.
    private func execRollupStatementWithoutBindings(_ db: OpaquePointer?, sql: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// COMMIT can fail after all statements have succeeded (for example when
    /// SQLite cannot obtain the final lock). Always close that transaction so
    /// the next retry can issue BEGIN successfully.
    private func commitTransaction(_ db: OpaquePointer?, failureMessage: String) -> Bool {
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            print("\(failureMessage): \(msg)")
            return false
        }
        return true
    }

    private func commitSampleLocked(_ sample: TrafficSample) {
        guard let db else { return }
        // A frame whose bucket was already rolled into `traffic_totals` no
        // longer has a ledger row, so the usual sample_id dedup would not see
        // it. Its id is tombstoned in `archived_samples` at rollup time; a
        // replay must stay a no-op or the same bytes would be counted twice.
        if sampleWasArchived(db, sampleID: sample.id) {
            print("[TrafficDatabase] sample \(sample.id) already archived; ignoring replay")
            return
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] BEGIN failed for sample \(sample.id): \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        var failed = false
        var stmt: OpaquePointer?
        let insertSample = """
        INSERT INTO traffic_samples(sample_id,captured_at_ms,bucket_start,day,hour,raw_in_bytes,raw_out_bytes,finalized)
        VALUES(?,?,?,?,?,?,?,0)
        ON CONFLICT(sample_id) DO NOTHING;
        """
        if sqlite3_prepare_v2(db, insertSample, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sample.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, sample.capturedAtMs)
            sqlite3_bind_int64(stmt, 3, Int64(sample.bucketStart))
            sqlite3_bind_int64(stmt, 4, Int64(sample.day))
            sqlite3_bind_int64(stmt, 5, Int64(sample.hour))
            sqlite3_bind_int64(stmt, 6, Int64(sample.rawInBytes))
            sqlite3_bind_int64(stmt, 7, Int64(sample.rawOutBytes))
            failed = sqlite3_step(stmt) != SQLITE_DONE
        } else {
            failed = true
        }
        sqlite3_finalize(stmt)
        stmt = nil

        if !failed {
            let existing = "SELECT raw_in_bytes, raw_out_bytes, finalized FROM traffic_samples WHERE sample_id = ?;"
            if sqlite3_prepare_v2(db, existing, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sample.id, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let rawIn = sqlite3_column_int64(stmt, 0)
                    let rawOut = sqlite3_column_int64(stmt, 1)
                    let finalized = sqlite3_column_int(stmt, 2) != 0
                    if rawIn != Int64(sample.rawInBytes) || rawOut != Int64(sample.rawOutBytes) {
                        failed = true
                    } else if finalized {
                        sqlite3_finalize(stmt)
                        _ = commitTransaction(db, failureMessage: "[TrafficDatabase] COMMIT failed for sample \(sample.id)")
                        return
                    }
                } else {
                    failed = true
                }
            } else {
                failed = true
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        if !failed {
            let finalize = "UPDATE traffic_samples SET finalized = 1 WHERE sample_id = ?;"
            if sqlite3_prepare_v2(db, finalize, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sample.id, -1, SQLITE_TRANSIENT)
                failed = sqlite3_step(stmt) != SQLITE_DONE
            } else {
                failed = true
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        if failed {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            print("[TrafficDatabase] rolled back sample \(sample.id): \(String(cString: sqlite3_errmsg(db)))")
        } else {
            _ = commitTransaction(db, failureMessage: "[TrafficDatabase] COMMIT failed for sample \(sample.id)")
        }
    }

    /// True when `sampleID` was already rolled up into `traffic_totals` and its
    /// frame rows deleted. Such ids are tombstoned in `archived_samples`.
    /// Runs on `dbQueue` (no active transaction needed).
    private func sampleWasArchived(_ db: OpaquePointer?, sampleID: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM archived_samples WHERE sample_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sampleID, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Read (each returns via a completion on the given queue)

    /// Daily totals for a range.
    func dailyTraffic(start: Int, end: Int, completion: @escaping ([DayTrafficRow]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            var rows: [DayTrafficRow] = []
            var stmt: OpaquePointer?
            let sql = "SELECT day, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ? GROUP BY day ORDER BY day;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                completion([]); return
            }
            sqlite3_bind_int64(stmt, 1, Int64(start))
            sqlite3_bind_int64(stmt, 2, Int64(end))
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(DayTrafficRow(
                    day: Int(sqlite3_column_int64(stmt, 0)),
                    inBytes: Int(sqlite3_column_int64(stmt, 1)),
                    outBytes: Int(sqlite3_column_int64(stmt, 2))
                ))
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Sum of all traffic within [start, end).
    func totalTraffic(start: Int, end: Int, completion: @escaping (TrafficTotal) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else {
                DispatchQueue.main.async { completion(TrafficTotal(inBytes: 0, outBytes: 0)) }
                return
            }
            var inBytes = 0, outBytes = 0
            var stmt: OpaquePointer?
            let sql = "SELECT SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(start))
                sqlite3_bind_int64(stmt, 2, Int64(end))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                        inBytes = Int(sqlite3_column_int64(stmt, 0))
                    }
                    if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                        outBytes = Int(sqlite3_column_int64(stmt, 1))
                    }
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(TrafficTotal(inBytes: inBytes, outBytes: outBytes)) }
        }
    }

    /// Whole-network totals for one local `day`, matching the dashboard's
    /// daily bars. Read through the accounted view so both the live ledger and
    /// rolled-up buckets are included.
    func dayTotalTraffic(day: Int, completion: @escaping (TrafficTotal) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else {
                DispatchQueue.main.async { completion(TrafficTotal(inBytes: 0, outBytes: 0)) }
                return
            }
            var inBytes = 0, outBytes = 0
            var stmt: OpaquePointer?
            let sql = "SELECT SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE day = ?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(day))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                        inBytes = Int(sqlite3_column_int64(stmt, 0))
                    }
                    if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                        outBytes = Int(sqlite3_column_int64(stmt, 1))
                    }
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(TrafficTotal(inBytes: inBytes, outBytes: outBytes)) }
        }
    }

    /// Total traffic series aggregated by minute / hour / day for charting.
    func trafficSeries(start: Int, end: Int, granularity: TimeSeriesGranularity,
                       completion: @escaping ([TrafficSeriesPoint]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            var rows: [TrafficSeriesPoint] = []
            var stmt: OpaquePointer?
            let sql: String
            switch granularity {
            case .minute:
                sql = """
                SELECT bucket_start, SUM(in_bytes), SUM(out_bytes)
                FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ?
                GROUP BY bucket_start ORDER BY bucket_start;
                """
            case .hour:
                sql = hourSeriesSQL
            case .day:
                sql = """
                SELECT day, SUM(in_bytes), SUM(out_bytes)
                FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ?
                GROUP BY day ORDER BY day;
                """
            }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                completion([]); return
            }
            sqlite3_bind_int64(stmt, 1, Int64(start))
            sqlite3_bind_int64(stmt, 2, Int64(end))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let period: Date
                switch granularity {
                case .minute, .hour:
                    period = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
                case .day:
                    period = dateFromDay(Int(sqlite3_column_int64(stmt, 0)))
                }
                rows.append(TrafficSeriesPoint(
                    date: period,
                    inBytes: Int(sqlite3_column_int64(stmt, 1)),
                    outBytes: Int(sqlite3_column_int64(stmt, 2))
                ))
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    // MARK: - Export

    /// Export total traffic rows within [start, end), one row per period.
    /// Period is a local-time Date for the bucket. Month rows are aggregated
    /// in Swift from day-granular data (no month column in the schema).
    func exportRows(start: Int, end: Int, granularity: ExportGranularity,
                    completion: @escaping ([ExportTrafficRow]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let rows: [ExportTrafficRow]
            switch granularity {
            case .minute:
                rows = self.exportTotals(db: db, start: start, end: end,
                                         sql: "SELECT bucket_start, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY bucket_start ORDER BY bucket_start;",
                                         period: { value, _ in Date(timeIntervalSince1970: TimeInterval(value)) })
            case .hour:
                rows = self.exportTotals(db: db, start: start, end: end,
                                         sql: "SELECT day, hour, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY day, hour ORDER BY day, hour;",
                                         hasHour: true,
                                         period: { day, hour in dateFromDay(day).addingTimeInterval(TimeInterval(hour) * 3600) })
            case .day:
                rows = self.exportTotals(db: db, start: start, end: end,
                                         sql: "SELECT day, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY day ORDER BY day;",
                                         period: { day, _ in dateFromDay(day) })
            case .month:
                let dayRows = self.exportTotals(db: db, start: start, end: end,
                                                sql: "SELECT day, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY day ORDER BY day;",
                                                period: { day, _ in dateFromDay(day) })
                rows = Self.aggregateMonths(dayRows)
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Run an export SQL (period column 0, optional hour column 1, then
    /// sum_in and sum_out) and map each row to an `ExportTrafficRow`.
    private func exportTotals(db: OpaquePointer?, start: Int, end: Int,
                              sql: String, hasHour: Bool = false,
                              period: (Int, Int) -> Date) -> [ExportTrafficRow] {
        var rows: [ExportTrafficRow] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        sqlite3_bind_int64(stmt, 1, Int64(start))
        sqlite3_bind_int64(stmt, 2, Int64(end))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let primary = Int(sqlite3_column_int64(stmt, 0))
            let date = hasHour
                ? period(primary, Int(sqlite3_column_int64(stmt, 1)))
                : period(primary, 0)
            let inIndex: Int32 = hasHour ? 2 : 1
            let outIndex: Int32 = hasHour ? 3 : 2
            rows.append(ExportTrafficRow(
                period: date,
                inBytes: Int(sqlite3_column_int64(stmt, inIndex)),
                outBytes: Int(sqlite3_column_int64(stmt, outIndex))
            ))
        }
        sqlite3_finalize(stmt)
        return rows
    }

    /// Re-group day rows into calendar-month rows (local timezone).
    static func aggregateMonths(_ dayRows: [ExportTrafficRow]) -> [ExportTrafficRow] {
        let calendar = Calendar.current
        var acc: [Date: (inBytes: Int, outBytes: Int)] = [:]
        for row in dayRows {
            let monthStart = calendar.dateInterval(of: .month, for: row.period)?.start ?? row.period
            var a = acc[monthStart] ?? (0, 0)
            a.inBytes += row.inBytes
            a.outBytes += row.outBytes
            acc[monthStart] = a
        }
        return acc
            .map { ExportTrafficRow(period: $0.key, inBytes: $0.value.inBytes, outBytes: $0.value.outBytes) }
            .sorted { $0.period < $1.period }
    }
}
