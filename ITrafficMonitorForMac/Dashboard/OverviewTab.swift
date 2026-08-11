//
//  OverviewTab.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

struct OverviewTab: View {
    @EnvironmentObject var viewModel: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    StatCard(title: "This Week", value: formatBytesTotal(bytes: viewModel.weekTotalBytes))
                    StatCard(title: "This Month", value: formatBytesTotal(bytes: viewModel.monthTotalBytes))
                    StatCard(title: "Month Projection", value: formatBytesTotal(bytes: viewModel.monthProjectedBytes))
                }

                GroupBox("Last 7 Days") {
                    Chart(viewModel.weekTrend, id: \.day) { row in
                        BarMark(
                            x: .value("Day", dateFromDay(row.day)),
                            y: .value("MB", Double(row.inBytes + row.outBytes) / 1_048_576)
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) {
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        }
                    }
                    .frame(height: 180)
                    .padding(.top, 4)
                }

                GroupBox("Monthly Top Apps") {
                    VStack(alignment: .leading, spacing: 8) {
                        if viewModel.monthTop.isEmpty {
                            Text("No data yet — traffic is being recorded.")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                        } else {
                            ForEach(Array(viewModel.monthTop.enumerated()), id: \.element.appKey) { index, row in
                                HStack(spacing: 8) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 20, alignment: .trailing)
                                    Text(row.displayName)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(formatBytesTotal(bytes: row.inBytes + row.outBytes))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .padding(16)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
