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
        let maxBytes = points.map { max($0.inBytes, $0.outBytes) }.max() ?? 0
        return maxBytes > 1_073_741_824 ? .gb : .mb
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
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(yUnit.label, yUnit.value(point.inBytes))
                )
                .foregroundStyle(Theme.download)
                .lineStyle(StrokeStyle(lineWidth: 2))

                LineMark(
                    x: .value("Time", point.date),
                    y: .value(yUnit.label, yUnit.value(point.outBytes))
                )
                .foregroundStyle(Theme.upload)
                .lineStyle(StrokeStyle(lineWidth: 2))
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
                               let point = nearestTrafficSeriesPoint(to: date, points: points) {
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

    private func tooltip(point: TrafficSeriesPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point.date.formatted(.dateTime.hour().minute()))
                .font(.system(size: 11, weight: .semibold))
            HStack(spacing: 10) {
                Text("↓ \(formatBytesTotal(bytes: point.inBytes))")
                    .foregroundStyle(Theme.download)
                Text("↑ \(formatBytesTotal(bytes: point.outBytes))")
                    .foregroundStyle(Theme.upload)
            }
            Text("总量 \(formatBytesTotal(bytes: point.inBytes + point.outBytes))")
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
        let start = points.first?.date ?? Date()
        let end = points.last?.date ?? start
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
