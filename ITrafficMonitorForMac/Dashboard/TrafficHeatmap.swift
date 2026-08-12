//
//  TrafficHeatmap.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

struct TrafficHeatmap: View {
    let cells: [HeatmapCell]
    let maxBytes: Int
    let emptyText: String

    /// Horizontal gap between hour cells (fraction of an hour).
    private let hourGap: Double = 0.12
    /// Vertical gap between day cells (hours at top/bottom of each day).
    private let dayGapHours: TimeInterval = 1.5 * 3600

    var body: some View {
        if cells.isEmpty {
            emptyState
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart(cells, id: \.self) { cell in
            RectangleMark(
                xStart: .value("Hour", Double(cell.hour) + hourGap / 2),
                xEnd: .value("Hour", Double(cell.hour) + 1 - hourGap / 2),
                yStart: .value("Day", dateFromDay(cell.day).addingTimeInterval(dayGapHours)),
                yEnd: .value("Day", dateFromDay(cell.day).addingTimeInterval(86400 - dayGapHours))
            )
            .foregroundStyle(cellColor(cell.totalBytes))
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text("\(hour)")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month().day())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cellColor(_ bytes: Int) -> Color {
        let ratio = Double(bytes) / Double(max(maxBytes, 1))
        // Ensure zero/low values are still visible while allowing high values to pop.
        return Theme.heatmap.opacity(0.22 + 0.78 * ratio)
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
