//
//  DashboardView.swift
//  ITrafficMonitorForMac
//

import SwiftUI

enum DashboardActionsPlacement: Equatable {
    case inlineTrailing
}

func dashboardActionsPlacement() -> DashboardActionsPlacement {
    .inlineTrailing
}

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject var i18n: LocalizationManager

    var body: some View {
        UnifiedDashboardView()
            .environmentObject(viewModel)
            .environment(\.locale, i18n.locale)
            .frame(minWidth: 900, minHeight: 600)
    }
}
