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
    static let statusItemWidth: CGFloat = 62
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

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 菜单栏按钮上覆盖了文本子视图，原 button action 已不生效；
        // 让整块区域（含文本行）统一由自身响应点击，避免子 label 拦截导致弹窗打不开。
        bounds.contains(point) ? self : nil
    }
}

struct MenuBarSummaryView: View {
    @EnvironmentObject private var statusDataModel: StatusDataModel
    @EnvironmentObject private var i18n: LocalizationManager

    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    private var snapshot: MenuBarSnapshot {
        MenuBarSnapshot(
            downloadRate: statusDataModel.totalInBytes,
            uploadRate: statusDataModel.totalOutBytes
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(AppDelegate.appDisplayName, systemImage: "network")
                    .font(.headline)
                Spacer()
                if snapshot.isIdle {
                    Text(i18n.text("Idle"))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                rateRow(
                    title: i18n.text("Download Speed"),
                    value: formatBytes(bytes: snapshot.downloadRate),
                    color: Theme.download,
                    symbol: "arrow.down"
                )
                rateRow(
                    title: i18n.text("Upload Speed"),
                    value: formatBytes(bytes: snapshot.uploadRate),
                    color: Theme.upload,
                    symbol: "arrow.up"
                )
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

    private func rateRow(title: String, value: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .frame(width: 16)
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let rateView: MenuBarRateView
    private var cancellables = Set<AnyCancellable>()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        rateView = MenuBarRateView(frame: NSRect(
            x: 0,
            y: 0,
            width: MenuBarLayout.statusItemWidth,
            height: MenuBarLayout.statusItemHeight
        ))
        super.init()

        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        statusItem.length = MenuBarLayout.statusItemWidth
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

        SharedStore.statusDataModel.$totalInBytes
            .combineLatest(SharedStore.statusDataModel.$totalOutBytes)
            .receive(on: RunLoop.main)
            .sink { [weak self] downloadRate, uploadRate in
                self?.rateView.update(downloadRate: downloadRate, uploadRate: uploadRate)
            }
            .store(in: &cancellables)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 190)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarSummaryView(
                onOpenDashboard: { [weak self] in self?.openDashboard() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { [weak self] in self?.quit() }
            )
            .withGlobalEnvironmentObjects()
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
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
