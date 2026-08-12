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

/// One upsert batch: app traffic rows plus the display-name map.
struct TrafficBatch {
    let bucketStart: Int          // epoch seconds, minute-aligned
    let day: Int                  // local day
    let hour: Int                 // local hour
    let rows: [AppTrafficRow]     // inBytes/outBytes are deltas within this bucket
}

final class TrafficDatabase {

    private let dbQueue = DispatchQueue(label: "traffic-db", qos: .utility)
    private var db: OpaquePointer?

    init() {
        dbQueue.sync {
            self.open()
        }
    }

    // MARK: - Lifecycle

    private func open() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ITraffic", isDirectory: true)
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let dbPath = appSupport.appendingPathComponent("traffic.sqlite3").path
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
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            print("[TrafficDatabase] migrate failed: \(msg)")
            return
        }
    }

    // MARK: - Write

    /// Commit one minute-bucket batch inside a transaction. Executes on dbQueue.
    func commitBatch(_ batch: TrafficBatch) {
        dbQueue.sync {
            commitBatchLocked(batch)
        }
    }

    private func commitBatchLocked(_ batch: TrafficBatch) {
        guard let db else { return }

        let insertTraffic = """
        INSERT INTO app_traffic(app_key,bucket_start,day,hour,in_bytes,out_bytes,sample_count)
        VALUES(?,?,?,?,?,?,1)
        ON CONFLICT(app_key,bucket_start) DO UPDATE SET
          in_bytes=in_bytes+excluded.in_bytes,
          out_bytes=out_bytes+excluded.out_bytes,
          sample_count=sample_count+1;
        """
        let insertApp = """
        INSERT INTO apps(app_key,display_name,last_seen) VALUES(?,?,?)
        ON CONFLICT(app_key) DO UPDATE SET display_name=excluded.display_name,last_seen=excluded.last_seen;
        """

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            print("[TrafficDatabase] BEGIN failed, dropping batch of \(batch.rows.count) rows: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        var failed = false

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertTraffic, -1, &stmt, nil) == SQLITE_OK {
            for row in batch.rows {
                sqlite3_bind_text(stmt, 1, row.appKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(batch.bucketStart))
                sqlite3_bind_int64(stmt, 3, Int64(batch.day))
                sqlite3_bind_int64(stmt, 4, Int64(batch.hour))
                sqlite3_bind_int64(stmt, 5, Int64(row.inBytes))
                sqlite3_bind_int64(stmt, 6, Int64(row.outBytes))
                if sqlite3_step(stmt) != SQLITE_DONE {
                    failed = true
                    print("[TrafficDatabase] upsert traffic failed: \(String(cString: sqlite3_errmsg(db)))")
                }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
            }
        } else {
            failed = true
            print("[TrafficDatabase] prepare traffic upsert failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
        stmt = nil

        if !failed {
            if sqlite3_prepare_v2(db, insertApp, -1, &stmt, nil) == SQLITE_OK {
                for row in batch.rows {
                    sqlite3_bind_text(stmt, 1, row.appKey, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, row.displayName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 3, Int64(batch.bucketStart))
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        failed = true
                        print("[TrafficDatabase] upsert app failed: \(String(cString: sqlite3_errmsg(db)))")
                    }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                }
            } else {
                failed = true
                print("[TrafficDatabase] prepare app upsert failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        }

        if failed {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            print("[TrafficDatabase] rolled back batch of \(batch.rows.count) rows")
        } else {
            let rc = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            if rc != SQLITE_OK {
                print("[TrafficDatabase] COMMIT failed: \(String(cString: sqlite3_errmsg(db)))")
            }
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
            FROM app_traffic WHERE bucket_start >= ? AND bucket_start < ?
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
            var sql = "SELECT day, SUM(in_bytes), SUM(out_bytes) FROM app_traffic WHERE bucket_start >= ? AND bucket_start < ?"
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
            let sql = "SELECT SUM(in_bytes), SUM(out_bytes) FROM app_traffic WHERE bucket_start >= ? AND bucket_start < ?;"
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

    /// Per-app daily totals within [start, end). One row per (app_key, day).
    func trafficMatrix(start: Int, end: Int, completion: @escaping ([TrafficMatrixRow]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let names = self.displayNameMap()
            var rows: [TrafficMatrixRow] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT app_key, day, SUM(in_bytes), SUM(out_bytes)
            FROM app_traffic WHERE bucket_start >= ? AND bucket_start < ?
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
                FROM app_traffic WHERE bucket_start >= ? AND bucket_start < ?
                GROUP BY bucket_start ORDER BY bucket_start;
                """
            case .hour:
                sql = """
                SELECT strftime('%s', datetime(bucket_start, 'unixepoch', 'localtime', 'start of hour')) AS hour_start,
                       SUM(in_bytes), SUM(out_bytes)
                FROM app_traffic WHERE bucket_start >= ? AND bucket_start < ?
                GROUP BY hour_start ORDER BY hour_start;
                """
            case .day:
                sql = """
                SELECT day, SUM(in_bytes), SUM(out_bytes)
                FROM app_traffic WHERE bucket_start >= ? AND bucket_start < ?
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
            let sql = """
            SELECT app_key, SUM(in_bytes), SUM(out_bytes), MAX(in_bytes + out_bytes)
            FROM app_traffic WHERE bucket_start >= ? AND bucket_start < ?
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
                                          sql: "SELECT app_key, bucket_start, SUM(in_bytes), SUM(out_bytes) FROM app_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY app_key, bucket_start ORDER BY bucket_start;",
                                          period: { a, _ in Date(timeIntervalSince1970: TimeInterval(a)) })
            case .hour:
                rows = self.exportGrouped(db: db, start: start, end: end, names: names,
                                          sql: "SELECT app_key, day, hour, SUM(in_bytes), SUM(out_bytes) FROM app_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY app_key, day, hour ORDER BY day, hour;",
                                          hasHour: true,
                                          period: { a, h in dateFromDay(a).addingTimeInterval(TimeInterval(h) * 3600) })
            case .day:
                rows = self.exportGrouped(db: db, start: start, end: end, names: names,
                                          sql: "SELECT app_key, day, SUM(in_bytes), SUM(out_bytes) FROM app_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY app_key, day ORDER BY day;",
                                          period: { a, _ in dateFromDay(a) })
            case .month:
                let dayRows = self.exportGrouped(db: db, start: start, end: end, names: names,
                                                 sql: "SELECT app_key, day, SUM(in_bytes), SUM(out_bytes) FROM app_traffic WHERE bucket_start>=? AND bucket_start<? GROUP BY app_key, day ORDER BY day;",
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
