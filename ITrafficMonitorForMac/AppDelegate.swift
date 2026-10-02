//
//  AppDelegate.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/19.
//

import Cocoa
import SwiftUI

func shouldOpenDashboardAtLaunch(arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.contains("--open-dashboard")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    static let appDisplayName = "iTraffic"

    static var dashboardWindow: NSWindow?
    static var settingsWindow: NSWindow?
    var network: Network!
    private var menuBarController: MenuBarController?

    /// Open (or reuse) the full dashboard window from the menu bar entry.
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
            window.setContentSize(NSSize(width: 380, height: 520))
            window.minSize = NSSize(width: 380, height: 340)
            // The settings form is taller than a fixed window, so let it resize
            // instead of forcing every section to scroll in a cramped frame.
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
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
        // Hosted tests run inside this process. Starting nettop / attribution or
        // building UI here would make a test run open the production database and
        // record the test machine's traffic. Stay completely inert under tests.
        if AppEnvironment.isRunningTests { return }
        AppDelegate.applyAppearance(UserDefaults.standard.string(forKey: "appAppearance") ?? "system")
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()

        // Wire the storyboard's Preferences… menu item (⌘,) to the settings window.
        if let prefs = NSApp.mainMenu?.item(at: 0)?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
            prefs.target = self
            prefs.action = #selector(showSettingsWindow(_:))
        }

        if shouldOpenDashboardAtLaunch() {
            DispatchQueue.main.async {
                Self.showDashboard()
            }
        }

        self.network = Network()
        menuBarController?.network = self.network
        self.network.startListenNetwork()
        SharedStore.utunTrafficSampler.onReferenceSample = { sample in
            SharedStore.trafficSamplingDiagnostics.recordReferenceSample(sample)
        }
        SharedStore.utunTrafficSampler.start()

        // The app is menu-bar-first. The full dashboard remains available from
        // the status item popover and the application menu.
    }

    /// Keep running in the background after the window is closed so nettop
    /// sampling and history recording continue.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopen the dashboard if macOS asks the accessory app to reactivate.
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
        if AppEnvironment.isRunningTests { return }
        print("applicationWillTerminate")
        network?.stopListenNetwork()
        SharedStore.utunTrafficSampler.stop()
        SharedStore.proxyAttributor.stop()
        SharedStore.recorder.flush()
    }
}
