//
//  MenuBar.swift
//  ITrafficMonitorForMac
//

import AppKit
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

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        super.init()

        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "network",
            accessibilityDescription: AppDelegate.appDisplayName
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.toolTip = AppDelegate.appDisplayName
        button.target = self
        button.action = #selector(togglePopover(_:))
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
