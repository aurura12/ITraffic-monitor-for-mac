//
//  SettingsView.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var i18n: LocalizationManager
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appearanceRaw = "system"

    @AppStorage("proxyAttributionEnabled") private var proxyEnabled = true
    @AppStorage("proxyAttributionType") private var proxyTypeRaw = "auto"
    @AppStorage("proxyAttributionBaseURL") private var proxyBaseURL = ""
    @AppStorage("proxyAttributionSecret") private var proxySecret = ""
    @ObservedObject private var proxy = SharedStore.proxyAttributor

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
            AppDelegate.refreshSettingsWindowTitle()
        }
    }
}
