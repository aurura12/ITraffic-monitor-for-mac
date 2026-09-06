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
    @ObservedObject private var sampling = SharedStore.trafficSamplingDiagnostics
    private let diagnostics = DiagnosticLogStore.shared
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

            Toggle(i18n.text("Launch at login"), isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))

            Section {
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
                Text(proxyDiagnosticSummary(proxy.diagnostic))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text(i18n.text("Proxy attribution"))
            } footer: {
                Text(i18n.text("Only same-frame confirmed proxy bytes are reassigned; unmatched bytes stay with Clash."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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
                diagnosticCounterRow(
                    title: i18n.text("nettop delta"),
                    value: sampling.snapshot.latestNettopDelta
                )
                diagnosticCounterRow(
                    title: i18n.text("Physical interface delta"),
                    value: sampling.snapshot.latestExternalDelta
                )
                diagnosticCounterRow(
                    title: i18n.text("VPN utun delta"),
                    value: sampling.snapshot.latestUTunDelta
                )
                Text(i18n.text("Reference counters are for comparison only and are not added to historical totals."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(i18n.text("Diagnostic Logs")) {
                Text(diagnostics.logURL.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button(i18n.text("Show in Finder")) {
                        diagnostics.revealInFinder()
                    }
                    Button(i18n.text("Export") + "…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "proxy-diagnostics.log"
                        guard panel.runModal() == .OK, let destination = panel.url else { return }
                        try? diagnostics.export(to: destination)
                    }
                    Button(i18n.text("Clear")) {
                        diagnostics.clear()
                    }
                    .foregroundColor(.red)
                }
                Text(i18n.text("Proxy attribution diagnostics are retained locally (up to 16 MB)."))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
    private func diagnosticCounterRow(title: String, value: UTunTrafficCounters?) -> some View {
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
