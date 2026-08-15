//
//  TrafficLineChart.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

func nearestTrafficSeriesPoint(to date: Date, points: [TrafficSeriesPoint]) -> TrafficSeriesPoint? {
    points.min { lhs, rhs in
        abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
    }
}

func trafficBucketEnd(for date: Date, timeRange: TimeRange, calendar: Calendar) -> Date {
    let start = trafficBucketStart(for: date, timeRange: timeRange, calendar: calendar)
    switch timeRange {
    case .today:
        return calendar.date(byAdding: .hour, value: 1, to: start) ?? start
    case .sevenDays, .thirtyDays:
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start
    }
}

func trafficBucketStart(for date: Date, timeRange: TimeRange, calendar: Calendar) -> Date {
    switch timeRange {
    case .today:
        return calendar.dateInterval(of: .hour, for: date)?.start ?? date
    case .sevenDays, .thirtyDays:
        return calendar.startOfDay(for: date)
    }
}

func trafficBucketRangeLabel(for date: Date, timeRange: TimeRange, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = timeRange == .today ? "HH:mm" : "yyyy-MM-dd"
    let start = trafficBucketStart(for: date, timeRange: timeRange, calendar: calendar)
    let end = trafficBucketEnd(for: start, timeRange: timeRange, calendar: calendar)
    return "\(formatter.string(from: start))–\(formatter.string(from: end))"
}

func trafficBarValue(for point: TrafficSeriesPoint) -> Int {
    point.inBytes + point.outBytes
}

struct TrafficLineChart: View {
    let points: [TrafficSeriesPoint]
    let timeRange: TimeRange
    let emptyText: String

    @State private var hoveredDate: Date?
    @State private var hoveredLocation: CGPoint = .zero

    private enum YUnit {
        case mb, gb
        var label: String {
            switch self {
            case .mb: return "MB"
            case .gb: return "GB"
            }
        }
        func value(_ bytes: Int) -> Double {
            switch self {
            case .mb: return Double(bytes) / 1_048_576
            case .gb: return Double(bytes) / 1_073_741_824
            }
        }
    }

    private var yUnit: YUnit {
        let maxBytes = points.map(trafficBarValue).max() ?? 0
        return maxBytes > 1_073_741_824 ? .gb : .mb
    }

    private struct PlottedBar: Identifiable {
        let start: Date
        let end: Date
        let value: Double

        var id: Date { start }
    }

    private var plottedBars: [PlottedBar] {
        points.map { point in
            PlottedBar(
                start: trafficBucketStart(for: point.date, timeRange: timeRange, calendar: .current),
                end: trafficBucketEnd(for: point.date, timeRange: timeRange, calendar: .current),
                value: yUnit.value(trafficBarValue(for: point))
            )
        }
    }

    private var xAxisStride: Calendar.Component {
        switch timeRange {
        case .today: return .hour
        case .sevenDays, .thirtyDays: return .day
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch timeRange {
        case .today:
            return .dateTime.hour()
        case .sevenDays, .thirtyDays:
            return .dateTime.month(.abbreviated).day()
        }
    }

    var body: some View {
        if points.isEmpty {
            emptyState
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(plottedBars) { bar in
                trafficBarMark(bar)
            }

            if let hoveredPoint {
                RuleMark(x: .value("Hovered time", hoveredPoint.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: xAxisStride, count: timeRange == .today ? 3 : 1)) {
                AxisValueLabel(format: xAxisFormat)
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(String(format: number >= 100 ? "%.0f" : "%.1f", number))
                    }
                }
                AxisGridLine()
            }
        }
        .chartYAxisLabel(yUnit.label)
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plotFrame = geometry[proxy.plotAreaFrame]
                            let plotX = min(
                                max(location.x - plotFrame.origin.x, 0),
                                plotFrame.width
                            )
                            if let date: Date = proxy.value(atX: plotX),
                               let point = points.first(where: { point in
                                   let start = trafficBucketStart(
                                       for: point.date,
                                       timeRange: timeRange,
                                       calendar: .current
                                   )
                                   return date >= start && date < trafficBucketEnd(
                                       for: start,
                                       timeRange: timeRange,
                                       calendar: .current
                                   )
                               }) ?? nearestTrafficSeriesPoint(to: date, points: points) {
                                hoveredDate = point.date
                                hoveredLocation = location
                            }
                        case .ended:
                            hoveredDate = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoveredPoint {
                tooltip(point: hoveredPoint)
                    .position(tooltipPosition(for: hoveredLocation, in: chartSize))
                    .allowsHitTesting(false)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { chartSize = geometry.size }
                    .onChange(of: geometry.size) { _, newSize in chartSize = newSize }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var chartSize: CGSize = .zero

    private var hoveredPoint: TrafficSeriesPoint? {
        guard let hoveredDate else { return nil }
        return points.first { $0.date == hoveredDate }
    }

    @ChartContentBuilder
    private func trafficBarMark(_ bar: PlottedBar) -> some ChartContent {
        BarMark(
            x: .value("Time", bar.start),
            yStart: .value(yUnit.label, 0),
            yEnd: .value(yUnit.label, bar.value),
            width: MarkDimension.fixed(18)
        )
        .foregroundStyle(Theme.download)
    }

    private func tooltip(point: TrafficSeriesPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trafficBucketRangeLabel(for: point.date, timeRange: timeRange, calendar: .current))
                .font(.system(size: 11, weight: .semibold))
            Text("流量 \(formatBytesTotal(bytes: trafficBarValue(for: point)))")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.cardStroke))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var xDomain: ClosedRange<Date> {
        if timeRange == .today, let first = points.first?.date {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: first)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? first
            return start...end
        }
        let start = points.first.map {
            trafficBucketStart(for: $0.date, timeRange: timeRange, calendar: .current)
        } ?? Date()
        let end = points.last.map {
            trafficBucketEnd(for: $0.date, timeRange: timeRange, calendar: .current)
        } ?? start
        return start...end
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(emptyText)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
