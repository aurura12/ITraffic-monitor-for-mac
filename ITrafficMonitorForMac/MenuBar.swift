//
//  MenuBar.swift
//  ITrafficMonitorForMac
//

import AppKit
import Combine
import SwiftUI

/// A small, testable snapshot of the rates shown in the menu bar popover.
struct MenuBarSnapshot: Equatable {
    let downloadRate: Int
    let uploadRate: Int

    init(downloadRate: Int, uploadRate: Int) {
        self.downloadRate = max(0, downloadRate)
        self.uploadRate = max(0, uploadRate)
    }

    var isIdle: Bool {
        downloadRate == 0 && uploadRate == 0
    }
}

struct MenuBarRateText: Equatable {
    let download: String
    let upload: String

    var rows: [String] {
        [upload, download]
    }

    init(downloadRate: Int, uploadRate: Int) {
        download = "↓ " + formatMenuBarRate(bytes: downloadRate)
        upload = "↑ " + formatMenuBarRate(bytes: uploadRate)
    }
}

enum MenuBarLayout {
    /// 状态项宽度自适应原生按钮内容，左右各留 2pt 的点击余量。
    static let statusItemHorizontalPadding: CGFloat = 4
    static let statusItemHeight: CGFloat = 22
}

/// Compact rate format for the narrow, two-line status item.
func formatMenuBarRate(bytes: Int) -> String {
    let kilobytes = Double(max(0, bytes)) / 1024
    if kilobytes < 1024 {
        if kilobytes < 10 {
            return String(format: "%.1fK/s", kilobytes)
        }
        return String(format: "%.0fK/s", kilobytes)
    }

    let megabytes = kilobytes / 1024
    if megabytes < 1024 {
        return String(format: "%.1fM/s", megabytes)
    }

    return String(format: "%.1fG/s", megabytes / 1024)
}

/// Today's traffic totals shown in the popover. Filled asynchronously from
/// the persisted per-frame samples, so the numbers survive app restarts and
/// stay consistent with the dashboard's daily bars.
final class TodayUsageModel: ObservableObject {
    @Published private(set) var inBytes = 0
    @Published private(set) var outBytes = 0

    func update(total: TrafficTotal) {
        inBytes = max(0, total.inBytes)
        outBytes = max(0, total.outBytes)
    }

    var totalBytes: Int {
        inBytes + outBytes
    }
}

struct MenuBarSummaryView: View {
    @EnvironmentObject private var i18n: LocalizationManager
    @ObservedObject var todayUsage: TodayUsageModel

    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AppDelegate.appDisplayName, systemImage: "network")
                    .font(.headline)
                Spacer()
                Text(i18n.text("Today's Usage"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            usageRow(
                title: i18n.text("Download"),
                bytes: todayUsage.inBytes,
                color: Theme.download,
                symbol: "arrow.down"
            )
            usageRow(
                title: i18n.text("Upload"),
                bytes: todayUsage.outBytes,
                color: Theme.upload,
                symbol: "arrow.up"
            )

            Divider()

            HStack(spacing: 8) {
                Text(i18n.text("Total"))
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatBytesTotal(bytes: todayUsage.totalBytes))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
            }

            Divider()

            HStack(spacing: 8) {
                Button(i18n.text("Open Dashboard"), action: onOpenDashboard)
                    .keyboardShortcut(.defaultAction)
                Button(i18n.text("Settings"), action: onOpenSettings)
                Button(i18n.text("Quit"), action: onQuit)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func usageRow(title: String, bytes: Int, color: Color, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .frame(width: 16)
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(formatBytesTotal(bytes: bytes))
                .font(.system(.body, design: .monospaced))
        }
    }
}

final class MenuBarController: NSObject {
    static let statusItemAutosaveName = "com.foamzou.ITrafficMonitorForMac.menuBar"

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private weak var statusButton: NSStatusBarButton?
    private let todayUsage = TodayUsageModel()
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        super.init()

        statusItem.autosaveName = Self.statusItemAutosaveName
        configureStatusItem()
        configurePopover()
        refreshTodayUsage()
        scheduleTodayUsageRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        statusButton = button
        let fallbackIcon = NSImage(
            systemSymbolName: "network",
            accessibilityDescription: AppDelegate.appDisplayName
        )
        fallbackIcon?.isTemplate = true
        button.image = fallbackIcon
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.isBordered = false
        button.toolTip = statusItemToolTip(downloadRate: 0, uploadRate: 0)
        button.target = self
        button.action = #selector(togglePopover(_:))
        resizeToFitContent()

        SharedStore.statusDataModel.$totalInBytes
            .combineLatest(SharedStore.statusDataModel.$totalOutBytes)
            .receive(on: RunLoop.main)
            .sink { [weak self] downloadRate, uploadRate in
                self?.updateStatusButton(downloadRate: downloadRate, uploadRate: uploadRate)
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton(downloadRate: Int, uploadRate: Int) {
        guard let button = statusButton else { return }
        button.toolTip = statusItemToolTip(downloadRate: downloadRate, uploadRate: uploadRate)
        resizeToFitContent()
    }

    private func statusItemToolTip(downloadRate: Int, uploadRate: Int) -> String {
        let text = MenuBarRateText(downloadRate: downloadRate, uploadRate: uploadRate)
        return AppDelegate.appDisplayName + "\n" + text.rows.joined(separator: "  ")
    }

    /// 使用标准图标尺寸，避免拥挤的菜单栏把状态项挤到不可见区域。
    private func resizeToFitContent() {
        guard statusButton != nil else { return }
        if statusItem.length != NSStatusItem.squareLength {
            statusItem.length = NSStatusItem.squareLength
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 214)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarSummaryView(
                todayUsage: todayUsage,
                onOpenDashboard: { [weak self] in self?.openDashboard() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { [weak self] in self?.quit() }
            )
            .withGlobalEnvironmentObjects()
        )
    }

    /// Query the current local day's total from the history database.
    private func refreshTodayUsage() {
        let day = dayIndex(for: Date(), calendar: .current)
        SharedStore.recorder.dayTotalTraffic(day: day) { [weak self] total in
            self?.todayUsage.update(total: total)
        }
    }

    /// While the popover stays open the day totals keep climbing; refresh
    /// every few seconds so the numbers stay live without polling the DB
    /// when the popover is hidden.
    private func scheduleTodayUsageRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.refreshTodayUsage()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshTodayUsage()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openDashboard() {
        popover.performClose(nil)
        AppDelegate.showDashboard()
    }

    private func openSettings() {
        popover.performClose(nil)
        AppDelegate.showSettings()
    }

    private func quit() {
        popover.performClose(nil)
        NSApp.terminate(nil)
    }
}
