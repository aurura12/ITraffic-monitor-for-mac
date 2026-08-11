//
//  DashboardView.swift
//  ITrafficMonitorForMac
//

import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            OverviewTab()
                .tabItem { Label("Overview", systemImage: "chart.bar.fill") }
            TrendsTab()
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
            MonthlyTopTab()
                .tabItem { Label("Monthly Top", systemImage: "trophy.fill") }
            RealtimeTab()
                .tabItem { Label("Realtime", systemImage: "waveform.path.ecg") }
            HeatmapTab()
                .tabItem { Label("Heatmap", systemImage: "square.grid.3x3.fill") }
        }
        .environmentObject(viewModel)
        .onAppear { viewModel.refreshAll() }
        .onReceive(refreshTimer) { _ in
            viewModel.refreshAll()
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
