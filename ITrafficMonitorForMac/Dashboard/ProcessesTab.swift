//
//  ProcessesTab.swift
//  ITrafficMonitorForMac
//
//  Live per-process traffic list. Formerly the menu-bar popover content,
//  now a dashboard tab.
//

import SwiftUI

struct ProcessesTab: View {
    @EnvironmentObject var viewModel: ListViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                let maxTotal = viewModel.items
                    .map { $0.inBytes + $0.outBytes }
                    .max() ?? 0
                ForEach(viewModel.items) { entity in
                    ProcessRow(processEntity: entity, maxTotal: maxTotal)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProcessRow: View {
    var processEntity: ProcessEntity
    var maxTotal: Int

    var body: some View {
        let appInfo = getAppInfo(pid: processEntity.pid, name: processEntity.name)
        let inActive  = processEntity.inBytes  > 0
        let outActive = processEntity.outBytes > 0
        let anyActive = inActive || outActive

        let total = processEntity.inBytes + processEntity.outBytes
        let totalRatio = maxTotal > 0 ? CGFloat(total) / CGFloat(maxTotal) : 0

        HStack(spacing: 8) {
            Image(nsImage: appInfo?.icon ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)

            Text(appInfo?.name ?? processEntity.name)
                .font(.system(size: 12, weight: anyActive ? .semibold : .regular))
                .foregroundColor(anyActive ? .primary : Color.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Down: same size as up; color only when active
            HStack(spacing: 2) {
                Text("↓")
                    .font(.system(size: 10))
                    .foregroundColor(inActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.inBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(inActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 44, alignment: .trailing)
            }

            // Up: symmetric — same dimensions, same color rules
            HStack(spacing: 2) {
                Text("↑")
                    .font(.system(size: 10))
                    .foregroundColor(outActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.outBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(outActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .background(
            // Single neutral activity bar. Length = this row's total
            // (in + out) / page-max-total. Direction info stays in
            // the numbers. Color.primary auto-adapts to dark mode.
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: proxy.size.width * totalRatio)
                    Spacer(minLength: 0)
                }
            }
        )
    }
}
