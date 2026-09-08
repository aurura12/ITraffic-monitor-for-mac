//
//  UnifiedDashboardView.swift
//  ITrafficMonitorForMac
//
//  Single-page dashboard: time range + chart mode controls, stat cards,
//  traffic timeline (line/heatmap), and an app ranking table.
//

import SwiftUI

func chartSectionUsesCardBackground(for mode: ChartMode) -> Bool {
    mode != .usage
}

enum DashboardLayoutMode: Equatable {
    case windowFillingChart
    case scrollingPage
}

func dashboardLayoutMode(for chartMode: ChartMode) -> DashboardLayoutMode {
    chartMode == .usage ? .windowFillingChart : .scrollingPage
}

struct UnifiedDashboardView: View {
    @EnvironmentObject var viewModel: DashboardViewModel
    @EnvironmentObject var i18n: LocalizationManager
    @EnvironmentObject var realtimeRateStore: RealtimeRateStore
    @EnvironmentObject var proxyAttributor: ProxyAttributor

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            GeometryReader { _ in
                switch dashboardLayoutMode(for: viewModel.chartMode) {
                case .windowFillingChart:
                    dashboardContent
                        .padding(.horizontal, dashboardHorizontalPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .scrollingPage:
                    ScrollView {
                        dashboardContent
                            .padding(16)
                    }
                }
            }
            .navigationDestination(for: AppNavTarget.self) { target in
                AppDetailView(target: target)
            }
            // Give the root its own title so popping back from an app's detail
            // view restores the window title instead of leaving the app's name.
            .navigationTitle(AppDelegate.appDisplayName)
            .onAppear { viewModel.refreshDashboard() }
            .onReceive(refreshTimer) { _ in viewModel.refreshDashboard() }
            .onChange(of: viewModel.timeRange) { viewModel.refreshDashboard() }
            .onChange(of: viewModel.chartMode) { viewModel.refreshDashboard() }
            .onChange(of: viewModel.barGranularity) { viewModel.refreshBarChart() }
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            statCards
            attributionNotice
            if dashboardLayoutMode(for: viewModel.chartMode) == .windowFillingChart {
                chartSection
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                chartSection
            }
            if viewModel.chartMode == .line {
                rankingSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dashboardHorizontalPadding: CGFloat {
        switch dashboardContentWidthMode(for: viewModel.chartMode) {
        case .expanded:
            return 8
        case .padded:
            return 16
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
            StatCard(
                title: i18n.text("Download Speed"),
                value: formatBytes(bytes: Int(latestRateSample?.inRate ?? 0)),
                accent: Theme.download
            )
            StatCard(
                title: i18n.text("Upload Speed"),
                value: formatBytes(bytes: Int(latestRateSample?.outRate ?? 0)),
                accent: Theme.upload
            )
        }
    }

    private var latestRateSample: RateSample? {
        realtimeRateStore.samples.last
    }

    private var attributionNotice: some View {
        let diagnostic = proxyAttributor.diagnostic
        let title: String
        let detail: String
        let color: Color

        switch diagnostic {
        case .idle:
            title = i18n.text("Attribution status")
            detail = i18n.text("Collecting proxy attribution status")
            color = .secondary
        case .notDetected:
            title = i18n.text("Direct process accounting")
            detail = i18n.text("Total traffic uses nettop bytes; apps are read directly from their sockets.")
            color = .green
        case let .detected(name, _, connectionCount, mappedConnectionCount, _):
            title = mappedConnectionCount == connectionCount
                ? i18n.text("Proxy mapping active")
                : i18n.text("Proxy mapping partly complete")
            detail = "\(name): \(mappedConnectionCount)/\(connectionCount) " +
                i18n.text("proxy connections mapped; unmatched bytes stay with the proxy.")
            color = mappedConnectionCount == connectionCount ? .blue : .orange
        case let .waitingForProxyRow(name, _, connectionCount, mappedConnectionCount, _):
            title = i18n.text("Proxy row not visible")
            detail = "\(name): \(mappedConnectionCount)/\(connectionCount) " +
                i18n.text("connections mapped; total remains conservative.")
            color = .orange
        case .apiUnavailable:
            title = i18n.text("Proxy mapping temporarily paused")
            detail = i18n.text("Existing total accounting continues; new proxy bytes stay with the proxy until the API recovers.")
            color = .orange
        case .authRequired:
            title = i18n.text("Proxy API needs a secret")
            detail = i18n.text("Total traffic continues to be recorded; proxy traffic cannot be mapped until the secret is configured.")
            color = .red
        }

        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.cardStroke))
        )
    }

    // MARK: - Chart section

    @ViewBuilder
    private var chartSection: some View {
        if chartSectionUsesCardBackground(for: viewModel.chartMode) {
            chartSectionContent
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .fill(Theme.cardBackground)
                        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.cardStroke))
                )
        } else {
            chartSectionContent
        }
    }

    private var chartSectionContent: some View {
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
            .frame(minHeight: 260, maxHeight: chartContentMaxHeight)
            .padding(.horizontal, Theme.cardPadding)
            .padding(.bottom, Theme.cardPadding)
        }
    }

    private var chartContentMaxHeight: CGFloat {
        dashboardLayoutMode(for: viewModel.chartMode) == .windowFillingChart
            ? .infinity
            : 360
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
            legendItem(color: Theme.download, label: i18n.text("Total Traffic"))
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
