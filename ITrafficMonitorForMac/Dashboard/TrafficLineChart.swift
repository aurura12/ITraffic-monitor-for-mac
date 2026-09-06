//
//  TrafficLineChart.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts
import AppKit

func nearestTrafficSeriesPoint(to date: Date, points: [TrafficSeriesPoint]) -> TrafficSeriesPoint? {
    points.min { lhs, rhs in
        abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
    }
}

func nearestTrafficBarIndex(to plotX: CGFloat, barCenters: [CGFloat]) -> Int? {
    guard !barCenters.isEmpty else { return nil }
    return barCenters.indices.min { lhs, rhs in
        abs(barCenters[lhs] - plotX) < abs(barCenters[rhs] - plotX)
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

func trafficBucketLabel(for date: Date, timeRange: TimeRange, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = timeRange == .today ? "HH:mm" : "yyyy-MM-dd"
    let start = trafficBucketStart(for: date, timeRange: timeRange, calendar: calendar)
    guard timeRange == .today else {
        return formatter.string(from: start)
    }
    let end = trafficBucketEnd(for: start, timeRange: timeRange, calendar: calendar)
    return "\(formatter.string(from: start))–\(formatter.string(from: end))"
}

func trafficXAxisLabel(for date: Date, timeRange: TimeRange, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = timeRange == .today ? "HH" : "MMM d"
    return formatter.string(from: trafficBucketStart(for: date, timeRange: timeRange, calendar: calendar))
}

func trafficBarValue(for point: TrafficSeriesPoint) -> Int {
    point.inBytes + point.outBytes
}

func trafficXAxisStrideCount(for timeRange: TimeRange) -> Int {
    switch timeRange {
    case .today: return 3
    case .sevenDays: return 1
    case .thirtyDays: return 5
    }
}

func trafficXAxisLabelsUseIntervalCentering(for timeRange: TimeRange) -> Bool {
    switch timeRange {
    case .today:
        return false
    case .sevenDays, .thirtyDays:
        return true
    }
}

func trafficXAxisLabelOffset(for label: String) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 11)
    let renderedWidth = (label as NSString).size(withAttributes: [.font: font]).width
    let axisHorizontalSpacing: CGFloat = 4
    return -(renderedWidth / 2 + axisHorizontalSpacing)
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

    private var xAxisStrideCount: Int {
        trafficXAxisStrideCount(for: timeRange)
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
                RuleMark(
                    x: .value(
                        "Hovered time",
                        trafficBucketStart(
                            for: hoveredPoint.date,
                            timeRange: timeRange,
                            calendar: .current
                        )
                    )
                )
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: xAxisStride, count: xAxisStrideCount)) { value in
                AxisValueLabel(
                    centered: trafficXAxisLabelsUseIntervalCentering(for: timeRange),
                    anchor: .center,
                    collisionResolution: .disabled
                ) {
                    if let date = value.as(Date.self) {
                        let label = trafficXAxisLabel(for: date, timeRange: timeRange, calendar: .current)
                        Text(label)
                            .fixedSize(horizontal: true, vertical: false)
                            .offset(
                                x: trafficXAxisLabelsUseIntervalCentering(for: timeRange)
                                    ? 0
                                    : trafficXAxisLabelOffset(for: label)
                            )
                    }
                }
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
                            guard let plotFrameAnchor = proxy.plotFrame else { return }
                            let plotFrame = geometry[plotFrameAnchor]
                            let plotX = min(
                                max(location.x - plotFrame.origin.x, 0),
                                plotFrame.width
                            )
                            let barCenters = plottedBars.enumerated().compactMap { index, bar -> (pointIndex: Int, center: CGFloat)? in
                                guard let center = proxy.position(forX: bar.start) else { return nil }
                                return (pointIndex: index, center: center)
                            }
                            if let nearestIndex = nearestTrafficBarIndex(
                                to: plotX,
                                barCenters: barCenters.map { $0.center }
                            ) {
                                let selectedBar = barCenters[nearestIndex]
                                let point = points[selectedBar.pointIndex]
                                hoveredDate = point.date
                                hoveredLocation = CGPoint(
                                    x: plotFrame.origin.x + selectedBar.center,
                                    y: location.y
                                )
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
            Text(trafficBucketLabel(for: point.date, timeRange: timeRange, calendar: .current))
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
