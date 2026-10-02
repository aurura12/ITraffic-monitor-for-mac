//
//  UnifiedDashboardView.swift
//  ITrafficMonitorForMac
//
//  Single-page dashboard: time range + chart mode controls, stat cards and a
//  traffic timeline (line / heatmap / usage).
//

import SwiftUI

func chartSectionUsesCardBackground(for mode: ChartMode) -> Bool {
    mode != .usage
}

enum DashboardLayoutMode: Equatable {
    case windowFillingChart
    case scrollingPage
}

enum DashboardTopSectionHeight: Equatable {
    case intrinsic
    case flexible
}

func dashboardTopSectionHeight(for chartMode: ChartMode) -> DashboardTopSectionHeight {
    chartMode == .usage ? .intrinsic : .flexible
}

func dashboardLayoutMode(for chartMode: ChartMode) -> DashboardLayoutMode {
    chartMode == .usage ? .windowFillingChart : .scrollingPage
}

func dashboardUsesSharedOuterScrollView(for _: ChartMode) -> Bool {
    true
}

struct UnifiedDashboardView: View {
    @EnvironmentObject var viewModel: DashboardViewModel
    @EnvironmentObject var i18n: LocalizationManager
    @EnvironmentObject var realtimeRateStore: RealtimeRateStore
    @State private var showExport = false

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            if dashboardUsesSharedOuterScrollView(for: viewModel.chartMode) {
                ScrollView {
                    dashboardContent
                        .padding(16)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: dashboardLayoutMode(for: viewModel.chartMode) == .windowFillingChart
                                ? geometry.size.height
                                : nil,
                            alignment: .topLeading
                        )
                }
            } else {
                dashboardContent
                    .padding(16)
            }
        }
        .onAppear { viewModel.refreshDashboard() }
        .onReceive(refreshTimer) { _ in viewModel.refreshDashboard() }
        .onChange(of: viewModel.timeRange) { viewModel.refreshDashboard() }
        .onChange(of: viewModel.chartMode) { viewModel.refreshDashboard() }
        .onChange(of: viewModel.barGranularity) { viewModel.refreshBarChart() }
        .sheet(isPresented: $showExport) {
            ExportView()
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            topSection(toolbar)
            topSection(statCards)
            if dashboardLayoutMode(for: viewModel.chartMode) == .windowFillingChart {
                chartSection
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                chartSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func topSection<Content: View>(_ content: Content) -> some View {
        switch dashboardTopSectionHeight(for: viewModel.chartMode) {
        case .intrinsic:
            content.fixedSize(horizontal: false, vertical: true)
        case .flexible:
            content
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
                dashboardActions
            }
            chartModePicker
        }
    }

    private var dashboardActions: some View {
        HStack(spacing: 8) {
            Button {
                AppDelegate.showSettings()
            } label: {
                Label(i18n.text("Settings"), systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

            Button {
                showExport = true
            } label: {
                Label(i18n.text("Export"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
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

    /// Titles for the range-scoped Download/Upload/Total cards. Outside Line
    /// mode the time-range picker is hidden, so append the active range to make
    /// the scope of the totals explicit.
    private func rangeScopedCardTitle(_ key: String) -> String {
        viewModel.chartMode == .line
            ? i18n.text(key)
            : i18n.text(key) + " · " + i18n.text(viewModel.timeRange.labelKey)
    }

    private var statCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: rangeScopedCardTitle("Download"),
                value: formatBytesTotal(bytes: viewModel.rangeTotal.inBytes),
                accent: Theme.download
            )
            StatCard(
                title: rangeScopedCardTitle("Upload"),
                value: formatBytesTotal(bytes: viewModel.rangeTotal.outBytes),
                accent: Theme.upload
            )
            StatCard(
                title: rangeScopedCardTitle("Total"),
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
                } else if viewModel.chartMode == .heatmap {
                    heatmapLegend
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
                        thresholds: viewModel.calendarHeatmapThresholds,
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

    private var heatmapLegend: some View {
        HStack(spacing: 4) {
            Text(i18n.text("No traffic"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 10, height: 10)
            Text(i18n.text("Less"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            ForEach(1..<heatmapLevelOpacities.count, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.heatmap.opacity(heatmapLevelOpacities[level]))
                    .frame(width: 10, height: 10)
            }
            Text(i18n.text("More"))
                .font(.system(size: 10))
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
