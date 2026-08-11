//
//  DashboardView.swift
//  ITrafficMonitorForMac
//

import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject var i18n: LocalizationManager
    @State private var showExport = false

    var body: some View {
        UnifiedDashboardView()
            .environmentObject(viewModel)
            .environment(\.locale, i18n.locale)
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                // Floating actions — .toolbar doesn't reliably render in a window
                // created programmatically via NSHostingController, and a
                // safeAreaInset bar keeps content from scrolling under it.
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
            .frame(minWidth: 900, minHeight: 600)
    }
}
