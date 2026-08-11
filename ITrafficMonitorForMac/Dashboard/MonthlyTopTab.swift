//
//  MonthlyTopTab.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

struct MonthlyTopTab: View {
    @EnvironmentObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Traffic by app — this month")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)

            if viewModel.monthTop.isEmpty {
                Spacer()
                Text("No data recorded this month yet.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Chart(viewModel.monthTop, id: \.appKey) { row in
                    BarMark(
                        x: .value("MB", Double(row.inBytes + row.outBytes) / 1_048_576),
                        y: .value("App", row.displayName)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .chartXAxisLabel("MB")
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let name = value.as(String.self) {
                                Text(name).lineLimit(1).truncationMode(.tail)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(16)
            }
        }
    }
}
