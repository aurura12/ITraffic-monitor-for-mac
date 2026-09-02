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

struct AppTrafficRow {
    let appKey: String
    let displayName: String
    let inBytes: Int
    let outBytes: Int
}

struct DayTrafficRow {
    let day: Int      // local days since 1970-01-01
    let inBytes: Int
    let outBytes: Int
}

struct TrafficTotal {
    let inBytes: Int
    let outBytes: Int
}

struct TrafficMatrixRow {
    let appKey: String
    let displayName: String
    let day: Int
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
    let appKey: String
    let displayName: String
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

struct TrafficPoint {
    let date: Date
    let inRate: Double
    let outRate: Double
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

struct AppPeakTrafficRow: Identifiable {
    let appKey: String
    let displayName: String
    let inBytes: Int
    let outBytes: Int
    let peakBytesPerSecond: Int
    var id: String { appKey }
    var totalBytes: Int { inBytes + outBytes }
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

struct TrafficSampleAllocation: Equatable {
    let appKey: String
    let displayName: String
    let inBytes: Int
    let outBytes: Int
}

struct TrafficSample: Equatable {
    let id: String
    let capturedAtMs: Int64
    let bucketStart: Int
    let day: Int
    let hour: Int
    let rawInBytes: Int
    let rawOutBytes: Int
    let allocations: [TrafficSampleAllocation]
}

final class TrafficDatabase {

    private let dbQueue = DispatchQueue(label: "traffic-db", qos: .utility)
    private let databaseURL: URL?
    private var db: OpaquePointer?

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
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        migrate()
    }

    private func migrate() {
        let schema = """
        CREATE TABLE IF NOT EXISTS app_traffic (
          app_key      TEXT NOT NULL,
          bucket_start INTEGER NOT NULL,
          day          INTEGER NOT NULL,
          hour         INTEGER NOT NULL,
          in_bytes     INTEGER NOT NULL DEFAULT 0,
          out_bytes    INTEGER NOT NULL DEFAULT 0,
          sample_count INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (app_key, bucket_start)
        );
        CREATE INDEX IF NOT EXISTS idx_traffic_bucket ON app_traffic(bucket_start);
        CREATE TABLE IF NOT EXISTS apps (
          app_key      TEXT PRIMARY KEY,
          display_name TEXT NOT NULL,
          last_seen    INTEGER NOT NULL
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
        CREATE TABLE IF NOT EXISTS sample_allocations (
          sample_id  TEXT NOT NULL,
          app_key    TEXT NOT NULL,
          in_bytes   INTEGER NOT NULL DEFAULT 0,
          out_bytes  INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (sample_id, app_key)
        );
        CREATE INDEX IF NOT EXISTS idx_sample_allocations_app ON sample_allocations(app_key);
        CREATE VIEW IF NOT EXISTS accounted_traffic AS
          SELECT app_key, bucket_start, day, hour, in_bytes, out_bytes
          FROM app_traffic
          UNION ALL
          SELECT a.app_key, s.bucket_start, s.day, s.hour, a.in_bytes, a.out_bytes
          FROM sample_allocations AS a
          JOIN traffic_samples AS s ON s.sample_id = a.sample_id
          WHERE s.finalized = 1;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            print("[TrafficDatabase] migrate failed: \(msg)")
            return
        }
        migrateClashVergeName()
        migrateUnattributedVPNName()
    }

    /// Merge rows written by older versions under the raw mihomo process name
    /// into the stable Clash Verge app key.
    private func migrateClashVergeName() {
        guard let db else { return }
        let sql = """
        INSERT INTO app_traffic(app_key,bucket_start,day,hour,in_bytes,out_bytes,sample_count)
        SELECT 'Clash Verge', bucket_start, day, hour, SUM(in_bytes), SUM(out_bytes), SUM(sample_count)
        FROM app_traffic
        WHERE app_key IN ('verge-mihomo', 'mihomo', 'io.github.clash-verge-rev.clash-verge-rev')
        GROUP BY bucket_start, day, hour
        ON CONFLICT(app_key,bucket_start) DO UPDATE SET
          in_bytes=in_bytes+excluded.in_bytes,
          out_bytes=out_bytes+excluded.out_bytes,
          sample_count=sample_count+excluded.sample_count;
        DELETE FROM app_traffic WHERE app_key IN ('verge-mihomo', 'mihomo', 'io.github.clash-verge-rev.clash-verge-rev');
        INSERT INTO apps(app_key,display_name,last_seen)
        SELECT 'Clash Verge', 'Clash Verge', COALESCE(MAX(last_seen), CAST(strftime('%s','now') AS INTEGER))
        FROM apps
        WHERE app_key IN ('verge-mihomo', 'mihomo', 'io.github.clash-verge-rev.clash-verge-rev')
        ON CONFLICT(app_key) DO UPDATE SET
          display_name='Clash Verge',
          last_seen=MAX(apps.last_seen, excluded.last_seen);
        DELETE FROM apps WHERE app_key IN ('verge-mihomo', 'mihomo', 'io.github.clash-verge-rev.clash-verge-rev');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] Clash Verge name migration failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    /// Merge rows written by older versions under the synthetic
    /// "Unattributed VPN" key into the Clash Verge app key. There is no
    /// unattributed-VPN category: traffic that cannot be mapped to an app is
    /// credited to the proxy process.
    private func migrateUnattributedVPNName() {
        guard let db else { return }
        let sql = """
        INSERT INTO app_traffic(app_key,bucket_start,day,hour,in_bytes,out_bytes,sample_count)
        SELECT 'Clash Verge', bucket_start, day, hour, SUM(in_bytes), SUM(out_bytes), SUM(sample_count)
        FROM app_traffic
        WHERE app_key = 'Unattributed VPN'
        GROUP BY bucket_start, day, hour
        ON CONFLICT(app_key,bucket_start) DO UPDATE SET
          in_bytes=in_bytes+excluded.in_bytes,
          out_bytes=out_bytes+excluded.out_bytes,
          sample_count=sample_count+excluded.sample_count;
        DELETE FROM app_traffic WHERE app_key = 'Unattributed VPN';
        DELETE FROM apps WHERE app_key = 'Unattributed VPN';
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] Unattributed VPN merge migration failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    // MARK: - Write

    /// Commit one finalized capture sample atomically. The sample identifier
    /// is the idempotency key: a retry of an already finalized sample is a
    /// no-op, so replaying a frame cannot inflate history.
    func commitSample(_ sample: TrafficSample) {
        let allocationIn = sample.allocations.reduce(0) { $0 + max(0, $1.inBytes) }
        let allocationOut = sample.allocations.reduce(0) { $0 + max(0, $1.outBytes) }
        guard sample.rawInBytes >= 0, sample.rawOutBytes >= 0,
              allocationIn == sample.rawInBytes,
              allocationOut == sample.rawOutBytes else {
            print("[TrafficDatabase] rejected non-conservative sample \(sample.id)")
            return
        }
        dbQueue.sync {
            commitSampleLocked(sample)
        }
    }

    private func commitSampleLocked(_ sample: TrafficSample) {
        guard let db else { return }
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
                        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
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
            let deleteAllocations = "DELETE FROM sample_allocations WHERE sample_id = ?;"
            if sqlite3_prepare_v2(db, deleteAllocations, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sample.id, -1, SQLITE_TRANSIENT)
                failed = sqlite3_step(stmt) != SQLITE_DONE
            } else {
                failed = true
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        if !failed {
            let insertAllocation = "INSERT INTO sample_allocations(sample_id,app_key,in_bytes,out_bytes) VALUES(?,?,?,?);"
            if sqlite3_prepare_v2(db, insertAllocation, -1, &stmt, nil) == SQLITE_OK {
                for allocation in sample.allocations where allocation.inBytes > 0 || allocation.outBytes > 0 {
                    sqlite3_bind_text(stmt, 1, sample.id, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, allocation.appKey, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 3, Int64(max(0, allocation.inBytes)))
                    sqlite3_bind_int64(stmt, 4, Int64(max(0, allocation.outBytes)))
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        failed = true
                        break
                    }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
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

        if !failed {
            let insertApp = """
            INSERT INTO apps(app_key,display_name,last_seen) VALUES(?,?,?)
            ON CONFLICT(app_key) DO UPDATE SET display_name=excluded.display_name,last_seen=MAX(apps.last_seen, excluded.last_seen);
            """
            if sqlite3_prepare_v2(db, insertApp, -1, &stmt, nil) == SQLITE_OK {
                for allocation in sample.allocations where allocation.inBytes > 0 || allocation.outBytes > 0 {
                    sqlite3_bind_text(stmt, 1, allocation.appKey, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, allocation.displayName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 3, Int64(sample.bucketStart))
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        failed = true
                        break
                    }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                }
            } else {
                failed = true
            }
            sqlite3_finalize(stmt)
        }

        if failed {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            print("[TrafficDatabase] rolled back sample \(sample.id): \(String(cString: sqlite3_errmsg(db)))")
        } else if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            print("[TrafficDatabase] COMMIT failed for sample \(sample.id): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - Read (each returns via a completion on the given queue)

    private func displayNameMap() -> [String: String] {
        guard let db else { return [:] }
        var map: [String: String] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT app_key, display_name FROM apps;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return map }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            map[key] = name
        }
        sqlite3_finalize(stmt)
        return map
    }

    /// Top apps by total (in+out) within [start, end).
    func topApps(start: Int, end: Int, limit: Int = 20, completion: @escaping ([AppTrafficRow]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let names = self.displayNameMap()
            var rows: [AppTrafficRow] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT app_key, SUM(in_bytes), SUM(out_bytes)
            FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ?
            GROUP BY app_key ORDER BY (SUM(in_bytes)+SUM(out_bytes)) DESC LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                completion([]); return
            }
            sqlite3_bind_int64(stmt, 1, Int64(start))
            sqlite3_bind_int64(stmt, 2, Int64(end))
            sqlite3_bind_int64(stmt, 3, Int64(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                rows.append(AppTrafficRow(
                    appKey: key,
                    displayName: names[key] ?? key,
                    inBytes: Int(sqlite3_column_int64(stmt, 1)),
                    outBytes: Int(sqlite3_column_int64(stmt, 2))
                ))
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Daily totals for a range (or a single app when appKey != nil).
    func dailyTraffic(start: Int, end: Int, appKey: String? = nil, completion: @escaping ([DayTrafficRow]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var rows: [DayTrafficRow] = []
            var stmt: OpaquePointer?
            var sql = "SELECT day, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ?"
            if appKey != nil { sql += " AND app_key = ?" }
            sql += " GROUP BY day ORDER BY day;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                completion([]); return
            }
            sqlite3_bind_int64(stmt, 1, Int64(start))
            sqlite3_bind_int64(stmt, 2, Int64(end))
            if let appKey {
                sqlite3_bind_text(stmt, 3, appKey, -1, SQLITE_TRANSIENT)
            }
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
            guard let self, let db = self.db else { return }
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
    /// daily bars. Read through the accounted view so both current samples
    /// and legacy app_traffic rows are included.
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

    /// Per-app daily totals within [start, end). One row per (app_key, day).
    func trafficMatrix(start: Int, end: Int, completion: @escaping ([TrafficMatrixRow]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let names = self.displayNameMap()
            var rows: [TrafficMatrixRow] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT app_key, day, SUM(in_bytes), SUM(out_bytes)
            FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ?
            GROUP BY app_key, day ORDER BY app_key, day;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                completion([]); return
            }
            sqlite3_bind_int64(stmt, 1, Int64(start))
            sqlite3_bind_int64(stmt, 2, Int64(end))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                rows.append(TrafficMatrixRow(
                    appKey: key,
                    displayName: names[key] ?? key,
                    day: Int(sqlite3_column_int64(stmt, 1)),
                    inBytes: Int(sqlite3_column_int64(stmt, 2)),
                    outBytes: Int(sqlite3_column_int64(stmt, 3))
                ))
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Total traffic series aggregated by minute / hour / day for charting.
    func trafficSeries(start: Int, end: Int, granularity: TimeSeriesGranularity,
                       completion: @escaping ([TrafficSeriesPoint]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
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

    /// Top apps by total traffic, including peak one-minute rate (bytes/sec).
    func topAppsWithPeak(start: Int, end: Int, limit: Int = 20,
                         completion: @escaping ([AppPeakTrafficRow]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let names = self.displayNameMap()
            var rows: [AppPeakTrafficRow] = []
            var stmt: OpaquePointer?
            // `accounted_traffic` holds one row per (sample, app): every 2s
            // nettop frame inserts its own rows under the same minute bucket.
            // A bare `MAX(in_bytes + out_bytes)` would therefore return the
            // largest single 2s frame (~30x smaller than a minute total).
            // Aggregate each minute bucket first, then take the peak minute.
            let sql = """
            SELECT app_key, SUM(in_bytes), SUM(out_bytes), MAX(minute_total)
            FROM (
              SELECT app_key, bucket_start,
                     SUM(in_bytes) AS in_bytes,
                     SUM(out_bytes) AS out_bytes,
                     SUM(in_bytes + out_bytes) AS minute_total
              FROM accounted_traffic WHERE bucket_start >= ? AND bucket_start < ?
              GROUP BY app_key, bucket_start
            )
            GROUP BY app_key ORDER BY (SUM(in_bytes)+SUM(out_bytes)) DESC LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                completion([]); return
            }
            sqlite3_bind_int64(stmt, 1, Int64(start))
            sqlite3_bind_int64(stmt, 2, Int64(end))
            sqlite3_bind_int64(stmt, 3, Int64(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                rows.append(AppPeakTrafficRow(
                    appKey: key,
                    displayName: names[key] ?? key,
                    inBytes: Int(sqlite3_column_int64(stmt, 1)),
                    outBytes: Int(sqlite3_column_int64(stmt, 2)),
                    peakBytesPerSecond: Int(sqlite3_column_int64(stmt, 3)) / 60
                ))
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    // MARK: - Export

    /// Export aggregated traffic rows within [start, end). Period label is a
    /// local-time Date for the bucket. Month rows are aggregated in Swift
    /// from day-granular data (no month column in the schema).
    func exportRows(start: Int, end: Int, granularity: ExportGranularity,
                    completion: @escaping ([ExportTrafficRow]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let names = self.displayNameMap()
            let rows: [ExportTrafficRow]
            switch granularity {
            case .minute:
                rows = self.exportGrouped(db: db, start: start, end: end, names: names,
                                          sql: "SELECT app_key, bucket_start, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY app_key, bucket_start ORDER BY bucket_start;",
                                          period: { a, _ in Date(timeIntervalSince1970: TimeInterval(a)) })
            case .hour:
                rows = self.exportGrouped(db: db, start: start, end: end, names: names,
                                          sql: "SELECT app_key, day, hour, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY app_key, day, hour ORDER BY day, hour;",
                                          hasHour: true,
                                          period: { a, h in dateFromDay(a).addingTimeInterval(TimeInterval(h) * 3600) })
            case .day:
                rows = self.exportGrouped(db: db, start: start, end: end, names: names,
                                          sql: "SELECT app_key, day, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY app_key, day ORDER BY day;",
                                          period: { a, _ in dateFromDay(a) })
            case .month:
                let dayRows = self.exportGrouped(db: db, start: start, end: end, names: names,
                                                 sql: "SELECT app_key, day, SUM(in_bytes), SUM(out_bytes) FROM accounted_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY app_key, day ORDER BY day;",
                                                 period: { a, _ in dateFromDay(a) })
                rows = Self.aggregateMonths(dayRows)
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Run an export SQL (expects `periodCol0`, optional `periodCol1`, sum_in, sum_out)
    /// and map rows to ExportTrafficRow with the given period builder.
    private func exportGrouped(db: OpaquePointer?, start: Int, end: Int, names: [String: String],
                               sql: String, hasHour: Bool = false,
                               period: (Int, Int) -> Date) -> [ExportTrafficRow] {
        var rows: [ExportTrafficRow] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        sqlite3_bind_int64(stmt, 1, Int64(start))
        sqlite3_bind_int64(stmt, 2, Int64(end))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let col1 = Int(sqlite3_column_int64(stmt, 1))
            let date: Date
            if hasHour {
                let hour = Int(sqlite3_column_int64(stmt, 2))
                date = period(col1, hour)
                rows.append(ExportTrafficRow(appKey: key, displayName: names[key] ?? key, period: date,
                                             inBytes: Int(sqlite3_column_int64(stmt, 3)),
                                             outBytes: Int(sqlite3_column_int64(stmt, 4))))
            } else {
                date = period(col1, 0)
                rows.append(ExportTrafficRow(appKey: key, displayName: names[key] ?? key, period: date,
                                             inBytes: Int(sqlite3_column_int64(stmt, 2)),
                                             outBytes: Int(sqlite3_column_int64(stmt, 3))))
            }
        }
        sqlite3_finalize(stmt)
        return rows
    }

    private struct MonthKey: Hashable {
        let appKey: String
        let displayName: String
        let monthStart: Date
    }

    /// Re-group day rows into calendar-month rows (local timezone).
    static func aggregateMonths(_ dayRows: [ExportTrafficRow]) -> [ExportTrafficRow] {
        let calendar = Calendar.current
        var acc: [MonthKey: (inBytes: Int, outBytes: Int)] = [:]
        for row in dayRows {
            let monthStart = calendar.dateInterval(of: .month, for: row.period)?.start ?? row.period
            let key = MonthKey(appKey: row.appKey, displayName: row.displayName, monthStart: monthStart)
            var a = acc[key] ?? (0, 0)
            a.inBytes += row.inBytes
            a.outBytes += row.outBytes
            acc[key] = a
        }
        return acc.map { key, value in
            ExportTrafficRow(appKey: key.appKey, displayName: key.displayName, period: key.monthStart,
                             inBytes: value.inBytes, outBytes: value.outBytes)
        }
        .sorted { $0.period < $1.period }
    }
}
