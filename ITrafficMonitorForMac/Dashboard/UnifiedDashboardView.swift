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
            .onChange(of: viewModel.timeRange) { _ in viewModel.refreshDashboard() }
            .onChange(of: viewModel.chartMode) { _ in viewModel.refreshDashboard() }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            timeRangePicker
            chartModePicker
            Spacer()
            toolbarActions
        }
    }

    private var timeRangePicker: some View {
        Picker("", selection: $viewModel.timeRange) {
            ForEach(TimeRange.allCases) { range in
                Text(i18n.text(range.labelKey)).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 360)
    }

    private var chartModePicker: some View {
        Picker("", selection: $viewModel.chartMode) {
            ForEach(ChartMode.allCases) { mode in
                Text(i18n.text(mode.labelKey)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
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
                    Text(i18n.text("Traffic Timeline"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(chartSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                legend
            }
            .padding(.horizontal, Theme.cardPadding)
            .padding(.top, Theme.cardPadding)

            ZStack {
                if viewModel.chartMode == .line {
                    TrafficLineChart(
                        points: viewModel.seriesPoints,
                        timeRange: viewModel.timeRange,
                        emptyText: i18n.text("No recorded traffic in this range.")
                    )
                } else {
                    TrafficHeatmap(
                        cells: viewModel.heatmapCells,
                        maxBytes: viewModel.heatmapMaxBytes,
                        emptyText: i18n.text("No recorded traffic in this range.")
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

    private var chartSubtitle: String {
        viewModel.chartMode == .line
            ? i18n.text("Drag to zoom any range")
            : i18n.text("Click any hour cell to zoom in")
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
