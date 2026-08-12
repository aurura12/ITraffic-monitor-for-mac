//
//  AppDelegate.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/19.
//

import Cocoa
import SwiftUI

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    static let appDisplayName = "iTraffic"

    static var dashboardWindow: NSWindow?
    static var settingsWindow: NSWindow?
    var network: Network!

    /// Open (or reuse) the dashboard window. This is the app's main window —
    /// shown on launch and reopened from the Dock after the user closes it.
    static func showDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: DashboardView().withGlobalEnvironmentObjects()
                )
            )
            window.title = Self.appDisplayName
            window.setContentSize(NSSize(width: 900, height: 640))
            window.minSize = NSSize(width: 900, height: 640)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            dashboardWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    /// Open (or reuse) the settings window, shared by the gear button and
    /// the Preferences menu item (⌘,).
    static func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SettingsView().withGlobalEnvironmentObjects()
                )
            )
            window.title = L("Settings")
            window.setContentSize(NSSize(width: 380, height: 340))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        AppDelegate.showSettings()
    }

    /// Keep the settings window title in sync with the active language.
    static func refreshSettingsWindowTitle() {
        settingsWindow?.title = L("Settings")
    }

    /// Apply a saved appearance ("system" / "light" / "dark") to the whole app.
    static func applyAppearance(_ raw: String) {
        switch raw {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.applyAppearance(UserDefaults.standard.string(forKey: "appAppearance") ?? "system")

        // Wire the storyboard's Preferences… menu item (⌘,) to the settings window.
        if let prefs = NSApp.mainMenu?.item(at: 0)?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
            prefs.target = self
            prefs.action = #selector(showSettingsWindow(_:))
        }

        self.network = Network()
        self.network.startListenNetwork()

        // Pierce Clash/Surge proxies so proxied traffic is attributed to the
        // real apps. No-ops when no proxy is detected.
        SharedStore.proxyAttributor.start()

        // Open the statistics dashboard as the main window.
        AppDelegate.showDashboard()
    }

    /// Keep running in the background after the window is closed so nettop
    /// sampling and history recording continue.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopen the dashboard window when the user clicks the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = AppDelegate.dashboardWindow, window.isMiniaturized {
                window.deminiaturize(nil)
            }
            AppDelegate.showDashboard()
        }
        return true
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        print("applicationWillTerminate")
        SharedStore.proxyAttributor.stop()
        SharedStore.recorder.flush()
    }
}
