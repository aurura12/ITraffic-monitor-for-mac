//
//  DashboardViewModel.swift
//  ITrafficMonitorForMac
//
//  Aggregates history queries for the unified dashboard.
//

import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case tenMinutes = "10 Minutes"
    case oneHour = "1 Hour"
    case today = "Today"
    case sevenDays = "7 Days"
    case thirtyDays = "30 Days"
    case thisMonth = "This Month"

    var id: String { rawValue }

    /// Localization key used by the UI.
    var labelKey: String { rawValue }

    /// Granularity to use for the line chart in this range.
    var seriesGranularity: TimeSeriesGranularity {
        switch self {
        case .tenMinutes, .oneHour: return .minute
        case .today: return .hour
        case .sevenDays, .thirtyDays, .thisMonth: return .day
        }
    }

    /// Number of days to render when this range is shown as a heatmap.
    var heatmapDays: Int {
        switch self {
        case .tenMinutes, .oneHour, .today: return 1
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .thisMonth: return 30
        }
    }

    /// Start (inclusive) and end (exclusive) epoch seconds for the range.
    func interval(calendar: Calendar = .current) -> (start: Int, end: Int) {
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let end = Int(tomorrow.timeIntervalSince1970)

        let start: Date
        switch self {
        case .tenMinutes:
            let s = calendar.date(byAdding: .minute, value: -10, to: now)!
            return (Int(s.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        case .oneHour:
            let s = calendar.date(byAdding: .hour, value: -1, to: now)!
            return (Int(s.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        case .today:
            start = todayStart
        case .sevenDays:
            start = calendar.date(byAdding: .day, value: -6, to: todayStart)!
        case .thirtyDays:
            start = calendar.date(byAdding: .day, value: -29, to: todayStart)!
        case .thisMonth:
            start = calendar.dateInterval(of: .month, for: now)!.start
        }
        return (Int(start.timeIntervalSince1970), end)
    }
}

enum ChartMode: String, CaseIterable, Identifiable {
    case line = "Line"
    case heatmap = "Heatmap"

    var id: String { rawValue }
    var labelKey: String { rawValue }
}

class DashboardViewModel: ObservableObject {

    // MARK: - Controls
    @Published var timeRange: TimeRange = .oneHour
    @Published var chartMode: ChartMode = .line
    @Published var appSearchText: String = ""

    // MARK: - Data
    @Published var seriesPoints: [TrafficSeriesPoint] = []
    @Published var rangeTotal: TrafficTotal = .init(inBytes: 0, outBytes: 0)
    @Published var rangeTopApps: [AppPeakTrafficRow] = []
    @Published var heatmapCells: [HeatmapCell] = []
    @Published var heatmapMaxBytes = 1

    private let recorder = SharedStore.recorder
    private let calendar = Calendar.current

    // MARK: - Refresh

    func refreshDashboard() {
        let interval = timeRange.interval(calendar: calendar)

        recorder.totalTraffic(start: interval.start, end: interval.end) { [weak self] total in
            self?.rangeTotal = total
        }

        recorder.topAppsWithPeak(start: interval.start, end: interval.end, limit: 50) { [weak self] rows in
            self?.rangeTopApps = rows
        }

        if chartMode == .line {
            recorder.trafficSeries(
                start: interval.start,
                end: interval.end,
                granularity: timeRange.seriesGranularity
            ) { [weak self] points in
                self?.seriesPoints = points
            }
        } else {
            refreshHeatmap()
        }
    }

    func refreshHeatmap() {
        let interval = timeRange.interval(calendar: calendar)
        recorder.heatmap(start: interval.start, end: interval.end) { [weak self] cells in
            guard let self else { return }
            self.heatmapCells = cells
            self.heatmapMaxBytes = max(cells.map(\.totalBytes).max() ?? 1, 1)
        }
    }
}
