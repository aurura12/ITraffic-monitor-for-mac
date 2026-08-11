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

    static var dashboardWindow: NSWindow?
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
            window.title = "iTraffic"
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

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.network = Network()
        self.network.startListenNetwork()

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
        SharedStore.recorder.flush()
    }
}
