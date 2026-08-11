//
//  AppRankingTable.swift
//  ITrafficMonitorForMac
//

import SwiftUI

/// Navigation value carrying the display name so the detail view doesn't
/// need to re-look it up.
struct AppNavTarget: Hashable {
    let appKey: String
    let displayName: String
}

enum RankingSort: Equatable {
    case name(ascending: Bool)
    case download(ascending: Bool)
    case upload(ascending: Bool)
    case peak(ascending: Bool)
    case total(ascending: Bool)

    static let `default` = RankingSort.total(ascending: false)

    var isAscending: Bool {
        switch self {
        case .name(let a), .download(let a), .upload(let a), .peak(let a), .total(let a):
            return a
        }
    }

    func toggled() -> RankingSort {
        switch self {
        case .name(let a): return .name(ascending: !a)
        case .download(let a): return .download(ascending: !a)
        case .upload(let a): return .upload(ascending: !a)
        case .peak(let a): return .peak(ascending: !a)
        case .total(let a): return .total(ascending: !a)
        }
    }

    func compare(_ lhs: AppPeakTrafficRow, _ rhs: AppPeakTrafficRow) -> Bool {
        let result: Bool
        switch self {
        case .name:
            result = lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        case .download:
            result = lhs.inBytes < rhs.inBytes
        case .upload:
            result = lhs.outBytes < rhs.outBytes
        case .peak:
            result = lhs.peakBytesPerSecond < rhs.peakBytesPerSecond
        case .total:
            result = lhs.totalBytes < rhs.totalBytes
        }
        return isAscending ? result : !result
    }
}

struct AppRankingTable: View {
    let rows: [AppPeakTrafficRow]
    @Binding var searchText: String
    @EnvironmentObject var i18n: LocalizationManager
    @State private var sort: RankingSort = .default

    private var filteredRows: [AppPeakTrafficRow] {
        let base = searchText.isEmpty
            ? rows
            : rows.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        return base.sorted { sort.compare($0, $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, Theme.cardPadding)
                .padding(.vertical, 10)

            Divider()
                .opacity(0.3)

            if filteredRows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRows) { row in
                            NavigationLink(value: AppNavTarget(appKey: row.appKey, displayName: row.displayName)) {
                                AppRankingRow(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.cardPadding)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            sortableHeader(key: "Name", width: nil, sort: .name(ascending: sort == .name(ascending: true)))
            Spacer()
            sortableHeader(key: "Download", width: 80, sort: .download(ascending: sort == .download(ascending: true)))
            sortableHeader(key: "Upload", width: 80, sort: .upload(ascending: sort == .upload(ascending: true)))
            sortableHeader(key: "Peak", width: 90, sort: .peak(ascending: sort == .peak(ascending: true)))
            sortableHeader(key: "Total", width: 90, sort: .total(ascending: sort == .total(ascending: true)))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.secondary)
    }

    private func sortableHeader(key: String, width: CGFloat?, sort activeSort: RankingSort) -> some View {
        Button {
            if sort == activeSort {
                sort = sort.toggled()
            } else {
                sort = activeSort
            }
        } label: {
            HStack(spacing: 2) {
                Text(i18n.text(key))
                if sort == activeSort || sort == activeSort.toggled() {
                    Image(systemName: sort.isAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        Text(i18n.text("No apps match the current filter."))
            .foregroundColor(.secondary)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

struct AppRankingRow: View {
    let row: AppPeakTrafficRow

    var body: some View {
        HStack(spacing: 8) {
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
            }

            Group {
                valueText(row.inBytes, width: 80)
                valueText(row.outBytes, width: 80)
                rateText(row.peakBytesPerSecond, width: 90)
                valueText(row.totalBytes, width: 90)
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func valueText(_ bytes: Int, width: CGFloat) -> some View {
        Text(formatBytesTotal(bytes: bytes))
            .frame(width: width, alignment: .trailing)
            .foregroundColor(.secondary)
    }

    private func rateText(_ bytesPerSecond: Int, width: CGFloat) -> some View {
        Text(formatBytes(bytes: bytesPerSecond))
            .frame(width: width, alignment: .trailing)
            .foregroundColor(.secondary)
    }
}
