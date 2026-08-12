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

    @AppStorage("proxyAttributionEnabled") private var proxyEnabled = true
    @AppStorage("proxyAttributionType") private var proxyTypeRaw = "auto"
    @AppStorage("proxyAttributionBaseURL") private var proxyBaseURL = ""
    @AppStorage("proxyAttributionSecret") private var proxySecret = ""
    @ObservedObject private var proxy = SharedStore.proxyAttributor
    @StateObject private var launchAtLogin = LaunchAtLoginManager()

    private var proxyStatusText: String {
        switch proxy.status {
        case .detected(let name):
            return L("Proxy detected") + ": \(name)"
        case .notDetected:
            return L("No proxy detected")
        case .secretRequired:
            return L("Secret required")
        case .disabled:
            return L("Off")
        }
    }

    var body: some View {
        Form {
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

            Toggle(i18n.text("Launch at login"), isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))

            Section(i18n.text("Proxy attribution")) {
                Toggle(i18n.text("Enable proxy attribution"), isOn: $proxyEnabled)
                    .onChange(of: proxyEnabled) { proxy.reconfigure() }
                Picker(i18n.text("Proxy type"), selection: $proxyTypeRaw) {
                    Text(i18n.text("Auto detect")).tag("auto")
                    Text(i18n.text("Clash")).tag("clash")
                    Text(i18n.text("Surge")).tag("surge")
                    Text(i18n.text("Off")).tag("off")
                }
                .onChange(of: proxyTypeRaw) { proxy.reconfigure() }
                TextField(i18n.text("API base URL"), text: $proxyBaseURL)
                    .onChange(of: proxyBaseURL) { proxy.reconfigure() }
                SecureField(i18n.text("Secret"), text: $proxySecret)
                    .onChange(of: proxySecret) { proxy.reconfigure() }
                HStack {
                    Text(proxyStatusText)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(i18n.text("Redetect")) {
                        proxy.reconfigure()
                    }
                    .controlSize(.small)
                }
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
}
