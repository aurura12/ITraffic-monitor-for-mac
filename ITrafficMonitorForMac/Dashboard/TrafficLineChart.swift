//
//  TrafficLineChart.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

struct TrafficLineChart: View {
    let points: [TrafficSeriesPoint]
    let timeRange: TimeRange
    let emptyText: String

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
        case .tenMinutes, .oneHour: return .minute
        case .today: return .hour
        case .sevenDays, .thirtyDays, .thisMonth: return .day
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch timeRange {
        case .tenMinutes, .oneHour, .today:
            return .dateTime.hour().minute()
        case .sevenDays, .thirtyDays, .thisMonth:
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
        Chart(points) { point in
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
        .chartXAxis {
            AxisMarks(values: .stride(by: xAxisStride)) {
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
        .chartYScale(domain: .automatic(includesZero: true))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
