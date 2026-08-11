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
                xStart: .value("Hour", cell.hour),
                xEnd: .value("Hour", cell.hour + 1),
                yStart: .value("Day", dateFromDay(cell.day)),
                yEnd: .value("Day", dateFromDay(cell.day).addingTimeInterval(86400))
            )
            .foregroundStyle(
                Theme.download.opacity(0.12 + 0.88 * Double(cell.totalBytes) / Double(max(maxBytes, 1)))
            )
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
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.month().day())
            }
        }
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
