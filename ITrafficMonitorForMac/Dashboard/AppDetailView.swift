//
//  AppDetailView.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import Charts

final class AppDetailViewModel: ObservableObject {
    let appKey: String

    @Published var daily: [DayTrafficRow] = []
    @Published var total7d = 0
    @Published var total30d = 0
    @Published var in30d = 0
    @Published var out30d = 0

    private let recorder = SharedStore.recorder
    private let calendar = Calendar.current

    init(appKey: String) {
        self.appKey = appKey
    }

    func load() {
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let start30 = calendar.date(byAdding: .day, value: -29, to: todayStart)!
        let start7 = calendar.date(byAdding: .day, value: -6, to: todayStart)!
        let endE = Int(tomorrow.timeIntervalSince1970)

        recorder.dailyTraffic(start: Int(start30.timeIntervalSince1970), end: endE, appKey: appKey) { [weak self] rows in
            guard let self else { return }
            self.daily = rows
            self.total30d = rows.reduce(0) { $0 + $1.inBytes + $1.outBytes }
            self.in30d = rows.reduce(0) { $0 + $1.inBytes }
            self.out30d = rows.reduce(0) { $0 + $1.outBytes }
        }
        recorder.dailyTraffic(start: Int(start7.timeIntervalSince1970), end: endE, appKey: appKey) { [weak self] rows in
            self?.total7d = rows.reduce(0) { $0 + $1.inBytes + $1.outBytes }
        }
    }
}

private struct DailyBar: Identifiable {
    let date: Date
    let inBytes: Int
    let outBytes: Int
    var id: Date { date }
}

struct AppDetailView: View {
    let target: AppNavTarget
    @EnvironmentObject var perAppRates: PerAppRateStore
    @EnvironmentObject var i18n: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AppDetailViewModel

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init(target: AppNavTarget) {
        self.target = target
        _viewModel = StateObject(wrappedValue: AppDetailViewModel(appKey: target.appKey))
    }

    /// 30 days ending today, zero-filled so the chart bars align on days.
    private var chartData: [DailyBar] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var byDay: [Int: DayTrafficRow] = [:]
        for row in viewModel.daily { byDay[row.day] = row }
        return (0..<30).compactMap { offset in
            let date = calendar.date(byAdding: .day, value: -(29 - offset), to: today)!
            let day = dayIndex(for: date, calendar: calendar)
            let row = byDay[day]
            return DailyBar(date: date, inBytes: row?.inBytes ?? 0, outBytes: row?.outBytes ?? 0)
        }
    }

    private var breakdownRows: [DailyBar] {
        Array(chartData.suffix(14).reversed())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                HStack(spacing: 16) {
                    StatCard(title: i18n.text("Last 7 Days"), value: formatBytesTotal(bytes: viewModel.total7d), accent: Theme.total)
                    StatCard(title: i18n.text("Last 30 Days"), value: formatBytesTotal(bytes: viewModel.total30d), accent: Theme.total)
                    StatCard(title: i18n.text("30d ↓ / ↑"), value: "\(formatBytesTotal(bytes: viewModel.in30d)) / \(formatBytesTotal(bytes: viewModel.out30d))", accent: Theme.total)
                }
                .padding(.horizontal, 16)

                GroupBox(i18n.text("Daily Traffic — Last 30 Days")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Circle().fill(Color.blue).frame(width: 8, height: 8)
                                Text(i18n.text("↓ Download")).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Color.orange).frame(width: 8, height: 8)
                                Text(i18n.text("↑ Upload")).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        Chart(chartData) { bar in
                            BarMark(
                                x: .value("Date", bar.date, unit: .day),
                                y: .value("MB", Double(bar.inBytes) / 1_048_576)
                            )
                            .foregroundStyle(Color.blue)

                            BarMark(
                                x: .value("Date", bar.date, unit: .day),
                                y: .value("MB", Double(bar.outBytes) / 1_048_576)
                            )
                            .foregroundStyle(Color.orange)
                        }
                        .chartYScale(domain: .automatic(includesZero: true))
                        .chartLegend(.hidden)
                        .frame(height: 200)
                    }
                    .padding(8)
                }
                .padding(.horizontal, 16)

                GroupBox(i18n.text("Daily Breakdown — Last 14 Days")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(i18n.text("Date")).frame(width: 90, alignment: .leading)
                            Text("↓").frame(width: 60, alignment: .trailing)
                            Text("↑").frame(width: 60, alignment: .trailing)
                            Text(i18n.text("Total")).frame(width: 70, alignment: .trailing)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)

                        Divider()

                        ForEach(breakdownRows) { bar in
                            HStack(spacing: 8) {
                                Text(bar.date, style: .date)
                                    .font(.system(size: 11))
                                    .frame(width: 90, alignment: .leading)
                                Text(formatBytesTotal(bytes: bar.inBytes))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 60, alignment: .trailing)
                                Text(formatBytesTotal(bytes: bar.outBytes))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 60, alignment: .trailing)
                                Text(formatBytesTotal(bytes: bar.inBytes + bar.outBytes))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle(target.displayName)
        .onAppear { viewModel.load() }
        .onReceive(refreshTimer) { _ in viewModel.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(i18n.text("Back"))

            Image(nsImage: iconForAppKey(target.appKey))
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let rates = perAppRates.latest[target.appKey] {
                    HStack(spacing: 10) {
                        Text("↓ \(formatBytes(bytes: Int(rates.inRate)))")
                        Text("↑ \(formatBytes(bytes: Int(rates.outRate)))")
                    }
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                } else {
                    Text(i18n.text("No active traffic"))
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}
