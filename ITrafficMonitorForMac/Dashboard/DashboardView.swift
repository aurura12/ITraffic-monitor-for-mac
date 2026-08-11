//
//  DashboardView.swift
//  ITrafficMonitorForMac
//

import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject var i18n: LocalizationManager
    @State private var showExport = false

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            OverviewTab()
                .tabItem { Label(i18n.text("Overview"), systemImage: "chart.bar.fill") }
            TrendsTab()
                .tabItem { Label(i18n.text("Trends"), systemImage: "chart.line.uptrend.xyaxis") }
            MonthlyTopTab()
                .tabItem { Label(i18n.text("Monthly Top"), systemImage: "trophy.fill") }
            RealtimeTab()
                .tabItem { Label(i18n.text("Realtime"), systemImage: "waveform.path.ecg") }
            HeatmapTab()
                .tabItem { Label(i18n.text("Heatmap"), systemImage: "square.grid.3x3.fill") }
            AppsTab()
                .tabItem { Label(i18n.text("Apps"), systemImage: "square.grid.2x2.fill") }
            ProcessesTab()
                .tabItem { Label(i18n.text("Processes"), systemImage: "list.bullet") }
        }
        .environmentObject(viewModel)
        .environment(\.locale, i18n.locale)
        .onAppear { viewModel.refreshAll() }
        .onReceive(refreshTimer) { _ in
            viewModel.refreshAll()
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            // Floating actions — .toolbar doesn't reliably render in a window
            // created programmatically via NSHostingController, and a
            // safeAreaInset bar keeps tab content from scrolling under it.
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
            .padding(10)
        }
        .sheet(isPresented: $showExport) {
            ExportView()
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
