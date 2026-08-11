//
//  DashboardViewModel.swift
//  ITrafficMonitorForMac
//
//  Aggregates history queries for the dashboard tabs. All DB access is
//  async on the recorder's serial queue; results arrive on the main thread.
//

import Foundation

enum TrendRange: String, CaseIterable, Identifiable {
    case week = "7 Days"
    case month = "30 Days"
    case thisMonth = "This Month"
    var id: String { rawValue }
}

struct AppSeries: Identifiable {
    let appKey: String
    let displayName: String
    let rows: [DayTrafficRow]
    var id: String { appKey }
    var totalBytes: Int { rows.reduce(0) { $0 + $1.inBytes + $1.outBytes } }
}

struct AppTrendPoint: Identifiable {
    let appKey: String
    let date: Date
    let totalBytes: Int
    var id: String { "\(appKey)-\(Int(date.timeIntervalSince1970))" }
}

class DashboardViewModel: ObservableObject {

    // Overview
    @Published var weekTotalBytes = 0
    @Published var monthTotalBytes = 0
    @Published var monthProjectedBytes = 0
    @Published var weekTrend: [DayTrafficRow] = []
    @Published var monthTop: [AppTrafficRow] = []

    // Apps list
    @Published var apps: [AppTrafficRow] = []

    // Trends
    @Published var trendRange: TrendRange = .week
    @Published var appSeries: [AppSeries] = []

    // Heatmap
    @Published var heatmapDays = 30
    @Published var heatmapCells: [HeatmapCell] = []
    @Published var heatmapMaxBytes = 1

    private let recorder = SharedStore.recorder

    func refreshAll() {
        refreshOverview()
        refreshApps()
        refreshTrends()
        refreshHeatmap(days: heatmapDays)
    }

    func refreshApps() {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let start = calendar.date(byAdding: .day, value: -29, to: todayStart)!
        recorder.topApps(
            start: Int(start.timeIntervalSince1970),
            end: Int(tomorrow.timeIntervalSince1970),
            limit: 200
        ) { [weak self] rows in
            self?.apps = rows
        }
    }

    func refreshOverview() {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart)!
        let monthInterval = calendar.dateInterval(of: .month, for: now)!

        let weekStartE = Int(weekStart.timeIntervalSince1970)
        let endE = Int(tomorrow.timeIntervalSince1970)
        let monthStartE = Int(monthInterval.start.timeIntervalSince1970)
        let monthEndE = Int(monthInterval.end.timeIntervalSince1970)

        // Month-end projection: used / elapsed days * days in month.
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let elapsed = max(1, (calendar.dateComponents([.day], from: monthInterval.start, to: now).day ?? 0) + 1)

        recorder.totalTraffic(start: weekStartE, end: endE) { [weak self] in
            self?.weekTotalBytes = $0.inBytes + $0.outBytes
        }
        // Single month query feeds both the total card and the projection.
        recorder.totalTraffic(start: monthStartE, end: monthEndE) { [weak self] in
            guard let self else { return }
            let total = $0.inBytes + $0.outBytes
            self.monthTotalBytes = total
            self.monthProjectedBytes = Int((Double(total) / Double(elapsed) * Double(daysInMonth)).rounded())
        }
        recorder.dailyTraffic(start: weekStartE, end: endE) { [weak self] in
            self?.weekTrend = $0
        }
        recorder.topApps(start: monthStartE, end: monthEndE, limit: 20) { [weak self] in
            self?.monthTop = $0
        }
    }

    func refreshTrends() {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let endE = Int(tomorrow.timeIntervalSince1970)

        let startE: Int
        switch trendRange {
        case .week:
            startE = Int(calendar.date(byAdding: .day, value: -6, to: todayStart)!.timeIntervalSince1970)
        case .month:
            startE = Int(calendar.date(byAdding: .day, value: -29, to: todayStart)!.timeIntervalSince1970)
        case .thisMonth:
            startE = Int(calendar.dateInterval(of: .month, for: now)!.start.timeIntervalSince1970)
        }

        recorder.trafficMatrix(start: startE, end: endE) { [weak self] rows in
            guard let self else { return }
            var grouped: [String: (name: String, rows: [DayTrafficRow])] = [:]
            for row in rows {
                if grouped[row.appKey] == nil {
                    grouped[row.appKey] = (row.displayName, [])
                }
                grouped[row.appKey]?.rows.append(
                    DayTrafficRow(day: row.day, inBytes: row.inBytes, outBytes: row.outBytes)
                )
            }
            let series = grouped
                .map { appKey, value in
                    AppSeries(
                        appKey: appKey,
                        displayName: value.name,
                        rows: value.rows.sorted { $0.day < $1.day }
                    )
                }
                .sorted { $0.totalBytes > $1.totalBytes }
            self.appSeries = Array(series.prefix(8))
        }
    }

    func refreshHeatmap(days: Int) {
        recorder.heatmap(days: days) { [weak self] cells in
            self?.heatmapCells = cells
            self?.heatmapMaxBytes = max(cells.map(\.totalBytes).max() ?? 1, 1)
        }
    }
}
