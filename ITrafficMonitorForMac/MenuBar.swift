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
    /// 状态项宽度自适应两行文本内容，左右各留 2pt 的点击余量。
    static let statusItemHorizontalPadding: CGFloat = 4
    static let statusItemHeight: CGFloat = 22
}

enum MenuBarStatusItemConfiguration {
    /// Keep the AppKit status-item identity stable across relaunches.
    static let autosaveName = "com.foamzou.ITrafficMonitorV2.menuBar"
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

final class MenuBarRateView: NSView {
    private let downloadLabel = NSTextField(labelWithString: "↓ 0.0K/s")
    private let uploadLabel = NSTextField(labelWithString: "↑ 0.0K/s")
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for label in [downloadLabel, uploadLabel] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            // 两行文本左对齐：保证上下两行首字符（↑/↓）在同一列，
            // 不受速率数值位数变化的影响；若用 .center 会因行宽不同而错位。
            label.alignment = .left
            label.lineBreakMode = .byClipping
            label.textColor = .labelColor
        }

        let stack = NSStackView(views: [uploadLabel, downloadLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(downloadRate: Int, uploadRate: Int) {
        let text = MenuBarRateText(downloadRate: downloadRate, uploadRate: uploadRate)
        downloadLabel.stringValue = text.download
        uploadLabel.stringValue = text.upload
    }

    /// 两行文本中较宽一行的宽度，用于让状态项宽度自适应内容、不占多余菜单栏空间。
    var neededWidth: CGFloat {
        max(
            downloadLabel.intrinsicContentSize.width,
            uploadLabel.intrinsicContentSize.width
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 菜单栏按钮上覆盖了文本子视图，原 button action 已不生效；
        // 让整块区域（含文本行）统一由自身响应点击，避免子 label 拦截导致弹窗打不开。
        bounds.contains(point) ? self : nil
    }
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
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let rateView: MenuBarRateView
    private let todayUsage = TodayUsageModel()
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        // frame 仅作初始占位，随后会被 button 的四边约束接管，
        // 实际水平宽度由 resizeToFitContent() 按文本内容自适应设置。
        rateView = MenuBarRateView(frame: NSRect(
            x: 0,
            y: 0,
            width: MenuBarLayout.statusItemHeight,
            height: MenuBarLayout.statusItemHeight
        ))
        super.init()

        statusItem.autosaveName = MenuBarStatusItemConfiguration.autosaveName
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
        button.image = nil
        button.title = ""
        button.isBordered = false
        button.toolTip = AppDelegate.appDisplayName
        rateView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(rateView)
        NSLayoutConstraint.activate([
            rateView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            rateView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            rateView.topAnchor.constraint(equalTo: button.topAnchor),
            rateView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        rateView.onClick = { [weak self] in self?.togglePopover(nil) }
        resizeToFitContent()

        SharedStore.statusDataModel.$totalInBytes
            .combineLatest(SharedStore.statusDataModel.$totalOutBytes)
            .receive(on: RunLoop.main)
            .sink { [weak self] downloadRate, uploadRate in
                self?.rateView.update(downloadRate: downloadRate, uploadRate: uploadRate)
                self?.resizeToFitContent()
            }
            .store(in: &cancellables)
    }

    /// 状态项宽度跟随两行文本中较宽一行自适应，避免固定宽度在菜单栏留白。
    private func resizeToFitContent() {
        let width = ceil(rateView.neededWidth) + MenuBarLayout.statusItemHorizontalPadding
        if width != statusItem.length {
            statusItem.length = width
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
