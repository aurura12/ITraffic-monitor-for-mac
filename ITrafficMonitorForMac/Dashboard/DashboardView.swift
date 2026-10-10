//
//  DashboardView.swift
//  ITrafficMonitorForMac
//

import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject var i18n: LocalizationManager
    @ObservedObject var visibility: WindowVisibilityState

    var body: some View {
        VisibilityAwareWindowContent(visibility: visibility, content: UnifiedDashboardView())
            .environmentObject(viewModel)
            .environment(\.locale, i18n.locale)
            .frame(minWidth: 900, minHeight: 600)
            .background(Theme.windowBackground)
    }
}
