//
//  SettingsView.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import AppKit
import ServiceManagement

final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published var errorMessage: String?

    private let statusProvider: () -> Bool
    private let setEnabled: (Bool) throws -> Void

    init(
        statusProvider: @escaping () -> Bool = {
            SMAppService.mainApp.status == .enabled
        },
        setEnabled: @escaping (Bool) throws -> Void = { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    ) {
        self.statusProvider = statusProvider
        self.setEnabled = setEnabled
        self.isEnabled = statusProvider()
    }

    func refresh() {
        isEnabled = statusProvider()
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            try setEnabled(enabled)
            refresh()
            errorMessage = nil
            return true
        } catch {
            refresh()
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var i18n: LocalizationManager
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appearanceRaw = "system"
    @AppStorage(MenuBarDisplayMode.defaultsKey) private var menuBarDisplayModeRaw = MenuBarDisplayMode.both.rawValue

    @ObservedObject private var sampling = SharedStore.trafficSamplingDiagnostics
    @StateObject private var launchAtLogin = LaunchAtLoginManager()

    var body: some View {
        Form {
            Section(i18n.text("Version")) {
                HStack {
                    Text(i18n.text("Version"))
                    Spacer()
                    Text(buildVersionString)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Picker(i18n.text("Language"), selection: $languageRaw) {
                Text(i18n.text("Follow System")).tag(AppLanguage.system.rawValue)
                Text("English").tag(AppLanguage.en.rawValue)
                Text("简体中文").tag(AppLanguage.zhHans.rawValue)
            }
            Picker(i18n.text("Appearance"), selection: $appearanceRaw) {
                Text(i18n.text("Follow System")).tag("system")
                Text(i18n.text("Light")).tag("light")
                Text(i18n.text("Dark")).tag("dark")
            }
            Picker(i18n.text("Menu Bar Display"), selection: $menuBarDisplayModeRaw) {
                Text(i18n.text("Download + Upload")).tag(MenuBarDisplayMode.both.rawValue)
                Text(i18n.text("Download only")).tag(MenuBarDisplayMode.downloadOnly.rawValue)
                Text(i18n.text("Upload only")).tag(MenuBarDisplayMode.uploadOnly.rawValue)
                Text(i18n.text("Icon only")).tag(MenuBarDisplayMode.iconOnly.rawValue)
            }
            .onChange(of: menuBarDisplayModeRaw) { _, _ in
                NotificationCenter.default.post(name: .menuBarDisplayModeDidChange, object: nil)
            }

            Toggle(i18n.text("Launch at login"), isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))

            Section(i18n.text("Traffic metric")) {
                Text(i18n.text("Totals use nettop non-loopback interface socket traffic; this is not a physical Wi-Fi/Ethernet counter."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(i18n.text("Sampling diagnostics")) {
                Text(samplingStatusText)
                    .foregroundColor(.secondary)
                if let last = sampling.snapshot.lastNettopSampleAt {
                    Text(i18n.text("Last nettop sample") + ": " + last.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if sampling.snapshot.droppedNettopRows > 0 {
                    Text(i18n.text("Skipped nettop rows") + ": \(sampling.snapshot.droppedNettopRows)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                diagnosticCounterRow(
                    title: i18n.text("nettop delta"),
                    value: sampling.snapshot.latestNettopDelta
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding(16)
        .onChange(of: languageRaw) { _, raw in
            i18n.setLanguage(AppLanguage(rawValue: raw) ?? .system)
            AppDelegate.refreshSettingsWindowTitle()
        }
        .onChange(of: appearanceRaw) { _, raw in
            AppDelegate.applyAppearance(raw)
        }
        .onAppear {
            launchAtLogin.refresh()
            AppDelegate.refreshSettingsWindowTitle()
        }
        .alert(
            i18n.text("Launch at login failed"),
            isPresented: Binding(
                get: { launchAtLogin.errorMessage != nil },
                set: { if !$0 { launchAtLogin.errorMessage = nil } }
            )
        ) {
            Button(i18n.text("OK")) { launchAtLogin.errorMessage = nil }
        } message: {
            Text(launchAtLogin.errorMessage ?? "")
        }
    }

    private var buildVersionString: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(marketing) · build \(build) · \(GeneratedBuildInfo.buildDate)"
    }

    private var samplingStatusText: String {
        switch sampling.snapshot.nettopStatus {
        case .waiting: return i18n.text("Waiting for nettop sample")
        case .active: return i18n.text("nettop sampling active")
        case .restarting: return i18n.text("nettop sampling restarting")
        }
    }

    @ViewBuilder
    private func diagnosticCounterRow(title: String, value: TrafficCounters?) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            if let value {
                Text("↓ \(formatBytesTotal(bytes: value.inBytes))  ↑ \(formatBytesTotal(bytes: value.outBytes))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(i18n.text("Unavailable"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

}
