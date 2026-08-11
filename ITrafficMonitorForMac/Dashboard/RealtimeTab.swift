//
//  RealtimeTab.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

struct RealtimeTab: View {
    @EnvironmentObject var realtimeStore: RealtimeRateStore
    @EnvironmentObject var i18n: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(i18n.text("Total network rate — last ~10 minutes"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(Color.blue).frame(width: 8, height: 8)
                    Text(i18n.text("↓ Download"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(i18n.text("↑ Upload"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            if realtimeStore.samples.isEmpty {
                Spacer()
                Text(i18n.text("Collecting samples…"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Chart(realtimeStore.samples) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("KB/s", sample.inRate / 1024)
                    )
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("KB/s", sample.outRate / 1024)
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartYAxisLabel("KB/s")
                .chartLegend(.hidden)
                .frame(maxHeight: .infinity)
                .padding(16)
            }
        }
    }
}
