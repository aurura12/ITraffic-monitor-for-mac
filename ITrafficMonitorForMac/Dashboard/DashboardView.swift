//
//  DashboardView.swift
//  ITrafficMonitorForMac
//

import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @State private var showExport = false

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
            AppsTab()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
            ProcessesTab()
                .tabItem { Label("Processes", systemImage: "list.bullet") }
        }
        .environmentObject(viewModel)
        .onAppear { viewModel.refreshAll() }
        .onReceive(refreshTimer) { _ in
            viewModel.refreshAll()
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            // Floating export action — .toolbar doesn't reliably render in a
            // window created programmatically via NSHostingController, and a
            // safeAreaInset bar keeps tab content from scrolling under it.
            Button {
                showExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .padding(10)
        }
        .sheet(isPresented: $showExport) {
            ExportView()
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
