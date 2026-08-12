//
//  DashboardViewModel.swift
//  ITrafficMonitorForMac
//
//  Aggregates history queries for the unified dashboard.
//

import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case sevenDays = "7 Days"
    case thirtyDays = "30 Days"

    var id: String { rawValue }

    /// Localization key used by the UI.
    var labelKey: String { rawValue }

    /// Granularity to use for the line chart in this range.
    var seriesGranularity: TimeSeriesGranularity {
        switch self {
        case .today: return .hour
        case .sevenDays, .thirtyDays: return .day
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
        case .today:
            start = todayStart
        case .sevenDays:
            start = calendar.date(byAdding: .day, value: -6, to: todayStart)!
        case .thirtyDays:
            start = calendar.date(byAdding: .day, value: -29, to: todayStart)!
        }
        return (Int(start.timeIntervalSince1970), end)
    }
}

enum ChartMode: String, CaseIterable, Identifiable {
    case line = "Line"
    case heatmap = "Heatmap"
    case usage = "Usage"

    var id: String { rawValue }
    var labelKey: String { rawValue }
}

/// Produces a fixed 24-point local-day series for the Today view. SQLite only
/// returns buckets that contain traffic, so missing hours must be materialized
/// as zeroes before the chart can represent the whole day.
func hourlySeriesPoints(points: [TrafficSeriesPoint], start: Date, calendar: Calendar) -> [TrafficSeriesPoint] {
    var pointsByHour: [Date: TrafficSeriesPoint] = [:]
    for point in points {
        let hourStart = calendar.dateInterval(of: .hour, for: point.date)?.start ?? point.date
        pointsByHour[hourStart] = point
    }

    return (0..<24).map { offset in
        let hourStart = calendar.date(byAdding: .hour, value: offset, to: start)!
        return pointsByHour[hourStart]
            ?? TrafficSeriesPoint(date: hourStart, inBytes: 0, outBytes: 0)
    }
}

/// Bucketing used by the horizontal usage bar chart.
enum BarGranularity: String, CaseIterable, Identifiable {
    case day, month, quarter, year

    var id: String { rawValue }

    /// Localization key used by the UI. Capitalized so the existing zh
    /// entries ("Day"/"Month"/"Quarter"/"Year") are matched; `id` stays the
    /// lowercase raw value.
    var labelKey: String {
        switch self {
        case .day: return "Day"
        case .month: return "Month"
        case .quarter: return "Quarter"
        case .year: return "Year"
        }
    }

    /// Label for a period-start date, using language-neutral digits.
    func label(for date: Date, calendar: Calendar) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = Locale(identifier: "en_US_POSIX")
        switch self {
        case .day:     df.dateFormat = "yyyy-MM-dd"
        case .month:   df.dateFormat = "yyyy-MM"
        case .quarter: df.dateFormat = "yyyy-'Q'q"
        case .year:    df.dateFormat = "yyyy"
        }
        return df.string(from: date)
    }

    /// Start Date of the bucket containing `date` (local time).
    func periodStart(for date: Date, calendar: Calendar) -> Date {
        switch self {
        case .day:
            return calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year:
            return calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
        case .quarter:
            let month = calendar.component(.month, from: date)
            let year = calendar.component(.year, from: date)
            let quarterFirstMonth = ((month - 1) / 3) * 3 + 1
            var comps = DateComponents()
            comps.year = year
            comps.month = quarterFirstMonth
            comps.day = 1
            return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
        }
    }

    /// Aggregate per-day rows into bars for this granularity, sorted
    /// oldest → newest. Days without traffic simply have no row (no zero-fill),
    /// which keeps every bar > 0 for the log scale.
    func aggregate(dayRows: [DayTrafficRow], calendar: Calendar) -> [BarPeriodPoint] {
        var totals: [Date: Int] = [:]
        for row in dayRows {
            let date = dateFromDay(row.day)
            let start = periodStart(for: date, calendar: calendar)
            totals[start, default: 0] += row.inBytes + row.outBytes
        }
        return totals
            .map { BarPeriodPoint(period: $0.key, label: label(for: $0.key, calendar: calendar), totalBytes: $0.value) }
            .sorted { $0.period < $1.period }
    }
}

/// X-axis scaling for the usage bar chart.
enum BarScaleMode: String, CaseIterable, Identifiable {
    case linear, log

    var id: String { rawValue }

    /// Localization key used by the UI. Capitalized to match the zh entries
    /// ("Linear"/"Log").
    var labelKey: String {
        switch self {
        case .linear: return "Linear"
        case .log: return "Log"
        }
    }
}

class DashboardViewModel: ObservableObject {

    // MARK: - Controls
    @Published var timeRange: TimeRange = .today
    @Published var chartMode: ChartMode = .line
    @Published var appSearchText: String = ""
    @Published var barGranularity: BarGranularity = .month
    @Published var barScaleMode: BarScaleMode = .linear

    // MARK: - Data
    @Published var seriesPoints: [TrafficSeriesPoint] = []
    @Published var rangeTotal: TrafficTotal = .init(inBytes: 0, outBytes: 0)
    @Published var rangeTopApps: [AppPeakTrafficRow] = []
    @Published var calendarCells: [CalendarDayCell] = []
    @Published var calendarMaxBytes = 1
    @Published var barPoints: [BarPeriodPoint] = []

    private let recorder = SharedStore.recorder
    private let calendar = Calendar.current
    private var allDayRows: [DayTrafficRow] = []

    // MARK: - Refresh

    func refreshDashboard() {
        let interval = timeRange.interval(calendar: calendar)

        recorder.totalTraffic(start: interval.start, end: interval.end) { [weak self] total in
            self?.rangeTotal = total
        }

        recorder.topAppsWithPeak(start: interval.start, end: interval.end, limit: 50) { [weak self] rows in
            self?.rangeTopApps = rows
        }

        switch chartMode {
        case .line:
            recorder.trafficSeries(
                start: interval.start,
                end: interval.end,
                granularity: timeRange.seriesGranularity
            ) { [weak self] points in
                guard let self else { return }
                if self.timeRange == .today {
                    let startDate = Date(timeIntervalSince1970: TimeInterval(interval.start))
                    self.seriesPoints = hourlySeriesPoints(
                        points: points,
                        start: startDate,
                        calendar: self.calendar
                    )
                } else {
                    self.seriesPoints = points
                }
            }
        case .heatmap:
            refreshHeatmap()
        case .usage:
            refreshBarChart()
        }
    }

    /// Load all per-day rows (permanent retention) and aggregate them into
    /// bars for the current granularity. `allDayRows` is cached so switching
    /// granularity only re-aggregates in memory.
    func refreshBarChart() {
        if allDayRows.isEmpty {
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
            recorder.dailyTraffic(start: 0, end: Int(end.timeIntervalSince1970)) { [weak self] rows in
                guard let self else { return }
                self.allDayRows = rows
                self.barPoints = self.barGranularity.aggregate(dayRows: rows, calendar: self.calendar)
            }
        } else {
            barPoints = barGranularity.aggregate(dayRows: allDayRows, calendar: calendar)
        }
    }

    /// Load per-day totals for the last 365 days, shown as a calendar heatmap.
    /// Independent of `timeRange` so the heatmap always spans a full year.
    func refreshHeatmap() {
        let interval = heatmapInterval()
        recorder.dailyTraffic(start: interval.start, end: interval.end) { [weak self] rows in
            guard let self else { return }
            let dense = self.densifyCalendar(rows: rows, interval: interval)
            self.calendarCells = dense
            self.calendarMaxBytes = max(dense.map(\.totalBytes).max() ?? 1, 1)
        }
    }

    /// One-year interval: from local midnight 364 days ago up to (but not
    /// including) tomorrow, giving 365 whole days.
    private func heatmapInterval() -> (start: Int, end: Int) {
        let todayStart = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -364, to: todayStart)!
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }

    /// Build a dense per-day list covering every day that overlaps
    /// `[start, end)`. Days without traffic are filled with `totalBytes: 0`.
    private func densifyCalendar(rows: [DayTrafficRow], interval: (start: Int, end: Int)) -> [CalendarDayCell] {
        let startDate = Date(timeIntervalSince1970: TimeInterval(interval.start))
        let endDate = Date(timeIntervalSince1970: TimeInterval(interval.end))
        let startDay = dayIndex(for: startDate, calendar: calendar)
        // end is exclusive; if it sits on local midnight, the day at endDate
        // itself is not part of the range, so the last included day is one
        // before. For mid-day end (10m / 1h ranges), endDate's day is included.
        let endIsMidnight = calendar.startOfDay(for: endDate) == endDate
        let lastDay = endIsMidnight
            ? dayIndex(for: endDate, calendar: calendar) - 1
            : dayIndex(for: endDate, calendar: calendar)
        guard startDay <= lastDay else { return [] }

        var totals: [Int: Int] = [:]
        for row in rows {
            totals[row.day] = row.inBytes + row.outBytes
        }

        var dense: [CalendarDayCell] = []
        dense.reserveCapacity(lastDay - startDay + 1)
        for day in startDay...lastDay {
            dense.append(CalendarDayCell(day: day, totalBytes: totals[day] ?? 0))
        }
        return dense
    }
}
