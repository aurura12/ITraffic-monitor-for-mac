//
//  HeatmapTab.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

struct HeatmapTab: View {
    @EnvironmentObject var viewModel: DashboardViewModel
    @EnvironmentObject var i18n: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(i18n.text("Range"), selection: $viewModel.heatmapDays) {
                Text(i18n.text("7 Days")).tag(7)
                Text(i18n.text("30 Days")).tag(30)
                Text(i18n.text("90 Days")).tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .onChange(of: viewModel.heatmapDays) { _ in
                viewModel.refreshHeatmap(days: viewModel.heatmapDays)
            }

            if viewModel.heatmapCells.isEmpty {
                Spacer()
                Text(i18n.text("No recorded traffic in this range."))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Chart(viewModel.heatmapCells, id: \.self) { cell in
                    RectangleMark(
                        xStart: .value("Hour", cell.hour),
                        xEnd: .value("Hour", cell.hour + 1),
                        yStart: .value("Day", dateFromDay(cell.day)),
                        yEnd: .value("Day", dateFromDay(cell.day).addingTimeInterval(86400))
                    )
                    .foregroundStyle(
                        Color.accentColor.opacity(0.12 + 0.88 * Double(cell.totalBytes) / Double(viewModel.heatmapMaxBytes))
                    )
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: 6)) { value in
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
                .frame(maxHeight: .infinity)
                .padding(16)
            }
        }
        .onAppear {
            viewModel.refreshHeatmap(days: viewModel.heatmapDays)
        }
    }
}
