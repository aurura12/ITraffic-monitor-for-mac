//
//  DashboardView.swift
//  ITrafficMonitorForMac
//

import SwiftUI

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
