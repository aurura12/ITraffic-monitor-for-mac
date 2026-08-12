//
//  UnifiedDashboardView.swift
//  ITrafficMonitorForMac
//
//  Single-page dashboard: time range + chart mode controls, stat cards,
//  traffic timeline (line/heatmap), and an app ranking table.
//

import SwiftUI

struct UnifiedDashboardView: View {
    @EnvironmentObject var viewModel: DashboardViewModel
    @EnvironmentObject var i18n: LocalizationManager

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    toolbar
                    statCards
                    chartSection
                    rankingSection
                }
                .padding(16)
            }
            .navigationDestination(for: AppNavTarget.self) { target in
                AppDetailView(target: target)
            }
            .onAppear { viewModel.refreshDashboard() }
            .onReceive(refreshTimer) { _ in viewModel.refreshDashboard() }
            .onChange(of: viewModel.timeRange) { viewModel.refreshDashboard() }
            .onChange(of: viewModel.chartMode) { viewModel.refreshDashboard() }
            .onChange(of: viewModel.barGranularity) { viewModel.refreshBarChart() }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        // ZStack keeps the chart-mode picker centered and stationary while the
        // time-range picker appears/disappears depending on the selected mode.
        ZStack {
            HStack(spacing: 12) {
                // The time range picker only affects the line chart / stat cards;
                // the heatmap always shows the last 365 days and the usage chart
                // shows all history, so hide it there.
                if viewModel.chartMode == .line {
                    timeRangePicker
                }
                Spacer()
                toolbarActions
            }
            chartModePicker
        }
    }

    private var timeRangePicker: some View {
        Picker("", selection: $viewModel.timeRange) {
            ForEach(TimeRange.allCases) { range in
                Text(i18n.text(range.labelKey)).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
    }

    private var chartModePicker: some View {
        Picker("", selection: $viewModel.chartMode) {
            ForEach(ChartMode.allCases) { mode in
                Text(i18n.text(mode.labelKey)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var toolbarActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button(i18n.text("All Networks")) {}
            } label: {
                Label(i18n.text("All Networks"), systemImage: "wifi")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                viewModel.refreshDashboard()
            } label: {
                Label(i18n.text("Refresh"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Stat cards

    private var statCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: i18n.text("Download"),
                value: formatBytesTotal(bytes: viewModel.rangeTotal.inBytes),
                accent: Theme.download
            )
            StatCard(
                title: i18n.text("Upload"),
                value: formatBytesTotal(bytes: viewModel.rangeTotal.outBytes),
                accent: Theme.upload
            )
            StatCard(
                title: i18n.text("Total"),
                value: formatBytesTotal(bytes: viewModel.rangeTotal.inBytes + viewModel.rangeTotal.outBytes),
                accent: Theme.total
            )
        }
    }

    // MARK: - Chart section

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chartTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(chartSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if viewModel.chartMode == .usage {
                    barScalePicker
                    barGranularityPicker
                } else {
                    legend
                }
            }
            .padding(.horizontal, Theme.cardPadding)
            .padding(.top, Theme.cardPadding)

            ZStack {
                switch viewModel.chartMode {
                case .line:
                    TrafficLineChart(
                        points: viewModel.seriesPoints,
                        timeRange: viewModel.timeRange,
                        emptyText: i18n.text("No recorded traffic in this range.")
                    )
                case .heatmap:
                    TrafficCalendarHeatmap(
                        cells: viewModel.calendarCells,
                        maxBytes: viewModel.calendarMaxBytes,
                        emptyText: i18n.text("No recorded traffic in this range."),
                        calendar: calendar(for: i18n)
                    )
                case .usage:
                    TrafficBarChartView(
                        points: viewModel.barPoints,
                        scaleMode: viewModel.barScaleMode,
                        emptyText: i18n.text("No recorded traffic yet.")
                    )
                }
            }
            .frame(minHeight: 260, maxHeight: 360)
            .padding(.horizontal, Theme.cardPadding)
            .padding(.bottom, Theme.cardPadding)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.cardStroke))
        )
    }

    private var chartTitle: String {
        viewModel.chartMode == .usage
            ? i18n.text("Traffic Usage")
            : i18n.text("Traffic Timeline")
    }

    private var chartSubtitle: String {
        switch viewModel.chartMode {
        case .line:   return i18n.text("Drag to zoom any range")
        case .heatmap: return i18n.text("Daily traffic per day")
        case .usage:  return barSubtitle
        }
    }

    /// Gregorian calendar localized to the active UI locale, so weekday
    /// layout and labels respect `firstWeekday` differences (Mon vs Sun).
    private func calendar(for i18n: LocalizationManager) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = i18n.locale
        return cal
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(color: Theme.download, label: i18n.text("Download"))
            legendItem(color: Theme.upload, label: i18n.text("Upload"))
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Usage bar chart controls

    private var barScalePicker: some View {
        Picker("", selection: $viewModel.barScaleMode) {
            ForEach(BarScaleMode.allCases) { mode in
                Text(i18n.text(mode.labelKey)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
    }

    private var barGranularityPicker: some View {
        Picker("", selection: $viewModel.barGranularity) {
            ForEach(BarGranularity.allCases) { granularity in
                Text(i18n.text(granularity.labelKey)).tag(granularity)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
    }

    private var barSubtitle: String {
        switch viewModel.barGranularity {
        case .day: return i18n.text("Daily usage")
        case .month: return i18n.text("Monthly usage")
        case .quarter: return i18n.text("Quarterly usage")
        case .year: return i18n.text("Yearly usage")
        }
    }

    // MARK: - Ranking section

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.text("App Ranking"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(i18n.text("Rank updates with visible range"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                searchField
            }
            .padding(.horizontal, Theme.cardPadding)
            .padding(.top, Theme.cardPadding)

            AppRankingTable(rows: viewModel.rangeTopApps, searchText: $viewModel.appSearchText)
                .frame(minHeight: 180)
                .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.cardStroke))
        )
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField(i18n.text("Search apps"), text: $viewModel.appSearchText)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .frame(width: 140)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)).opacity(0.5))
    }
}

// MARK: - Stat card

struct StatCard: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(accent)
            }
            .padding(.vertical, 14)

            Spacer()
        }
        .padding(.leading, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.cardStroke))
        )
    }
}
