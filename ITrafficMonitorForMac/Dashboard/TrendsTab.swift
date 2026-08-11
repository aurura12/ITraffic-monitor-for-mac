//
//  TrendsTab.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

struct TrendsTab: View {
    @EnvironmentObject var viewModel: DashboardViewModel
    @EnvironmentObject var i18n: LocalizationManager

    private var points: [AppTrendPoint] {
        viewModel.appSeries.flatMap { series in
            series.rows.map { row in
                AppTrendPoint(
                    appKey: series.appKey,
                    date: dateFromDay(row.day),
                    totalBytes: row.inBytes + row.outBytes
                )
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(i18n.text("Range"), selection: $viewModel.trendRange) {
                ForEach(TrendRange.allCases) { range in
                    Text(i18n.text(range.rawValue)).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            if points.isEmpty {
                Spacer()
                Text(i18n.text("No recorded traffic in this range."))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("MB", Double(point.totalBytes) / 1_048_576)
                    )
                    .foregroundStyle(by: .value("App", point.appKey))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartLegend(position: .bottom)
                .chartYAxisLabel("MB")
                .frame(maxHeight: .infinity)
                .padding(16)
            }
        }
        .onChange(of: viewModel.trendRange) { _ in
            viewModel.refreshTrends()
        }
    }
}
