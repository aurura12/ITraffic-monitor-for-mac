//
//  ProcessEntity.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//
import Cocoa
import Foundation

func canonicalProcessDisplayName(_ name: String) -> String {
    switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "verge-mihomo", "mihomo", "clash-verge", "clash verge", "clash verge.app":
        return "Clash Verge"
    default:
        return name
    }
}

struct ProcessEntity: Identifiable {
    var id = UUID()
    
    public var pid: Int;
    public var name: String;
    public var inBytes: Int;
    public var outBytes: Int;
    public var icon: NSImage?;
    
    public init(pid: Int, name: String, inBytes: Int, outBytes: Int) {
        self.pid = pid
        self.name = name
        self.inBytes = inBytes
        self.outBytes = outBytes
        self.icon = nil
    }

    /// Stable identity for history: bundle identifier when available,
    /// otherwise the display name (e.g. "iTerm2 · node") that the CLI
    /// ancestor walk produced. Falls back to the raw process name.
    /// Helper / service / WebKit daemons are attributed to the app that
    /// owns them (see `owningAppForProcess`).
    public var appKey: String {
        if canonicalProcessDisplayName(name) == "Clash Verge" {
            return "Clash Verge"
        }
        let info = getAppInfo(pid: pid, name: name)
        if info?.bundleIdentifier == "io.github.clash-verge-rev.clash-verge-rev" {
            return "Clash Verge"
        }
        if let host = owningAppForProcess(pid: pid, ownBundleId: info?.bundleIdentifier, ownDisplayName: info?.name) {
            return host.bundleId
        }
        if let bundleId = info?.bundleIdentifier, !bundleId.isEmpty {
            return bundleId
        }
        return displayName
    }

    public var displayName: String {
        if canonicalProcessDisplayName(name) == "Clash Verge" {
            return "Clash Verge"
        }
        let info = getAppInfo(pid: pid, name: name)
        if info?.bundleIdentifier == "io.github.clash-verge-rev.clash-verge-rev" {
            return "Clash Verge"
        }
        if let host = owningAppForProcess(pid: pid, ownBundleId: info?.bundleIdentifier, ownDisplayName: info?.name) {
            return host.name
        }
        return info?.name ?? name
    }

    /// True when the process has its own bundle identifier that is NOT the
    /// owning app's — i.e. a helper whose traffic the Network Extension
    /// reports under the helper's own bundle id. Those bytes are recorded
    /// via the nettop path (attributed to the owning app) instead.
    public var isFilterUnattributableHelper: Bool {
        guard let info = getAppInfo(pid: pid, name: name),
              let ownBundleId = info.bundleIdentifier, !ownBundleId.isEmpty else {
            return false
        }
        return owningAppForProcess(pid: pid, ownBundleId: ownBundleId, ownDisplayName: info.name) != nil
    }

    /// The process's own bundle identifier, before any owning-app merge.
    public var ownBundleIdentifier: String? {
        getAppInfo(pid: pid, name: name)?.bundleIdentifier
    }
}
