//
//  AppsTab.swift
//  ITrafficMonitorForMac
//

import SwiftUI

/// Navigation value carrying the display name so the detail view doesn't
/// need to re-look it up.
struct AppNavTarget: Hashable {
    let appKey: String
    let displayName: String
}

struct AppsTab: View {
    @EnvironmentObject var viewModel: DashboardViewModel
    @EnvironmentObject var i18n: LocalizationManager
    @State private var searchText = ""

    private var filtered: [AppTrafficRow] {
        guard !searchText.isEmpty else { return viewModel.apps }
        return viewModel.apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.appKey) { row in
                NavigationLink(value: AppNavTarget(appKey: row.appKey, displayName: row.displayName)) {
                    AppRow(row: row)
                }
            }
            .searchable(text: $searchText, prompt: i18n.text("Search apps"))
            .navigationDestination(for: AppNavTarget.self) { target in
                AppDetailView(target: target)
            }
            .navigationTitle(i18n.text("Apps"))
        }
    }
}

struct AppRow: View {
    let row: AppTrafficRow

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: iconForAppKey(row.appKey))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(row.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(formatBytesTotal(bytes: row.inBytes + row.outBytes))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
