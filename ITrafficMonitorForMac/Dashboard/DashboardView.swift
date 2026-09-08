//
//  DashboardView.swift
//  ITrafficMonitorForMac
//

import SwiftUI

enum DashboardActionsPlacement: Equatable {
    case topTrailing
}

func dashboardActionsPlacement() -> DashboardActionsPlacement {
    .topTrailing
}

enum DashboardContentWidthMode: Equatable {
    case expanded
    case padded
}

func dashboardContentWidthMode(for chartMode: ChartMode) -> DashboardContentWidthMode {
    chartMode == .usage ? .expanded : .padded
}

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject var i18n: LocalizationManager
    @State private var showExport = false

    var body: some View {
        UnifiedDashboardView()
            .environmentObject(viewModel)
            .environment(\.locale, i18n.locale)
            .safeAreaInset(edge: dashboardActionInsetEdge, alignment: .trailing) {
                // Keep actions in the top safe area so the chart can use the
                // full height below without a bottom action strip.
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .sheet(isPresented: $showExport) {
                ExportView()
            }
            .frame(minWidth: 900, minHeight: 600)
    }

    private var dashboardActionInsetEdge: VerticalEdge {
        switch dashboardActionsPlacement() {
        case .topTrailing:
            return .top
        }
    }
}
