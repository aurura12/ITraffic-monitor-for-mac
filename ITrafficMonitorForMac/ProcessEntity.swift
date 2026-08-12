//
//  ProcessEntity.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//
import Cocoa
import Foundation

let unattributedTunnelAppKey = "com.itraffic.unattributed-tunnel"
let unattributedTunnelProcessLabel = "VPN/TUN 未识别流量"

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
    public var appKey: String {
        if name == unattributedTunnelProcessLabel {
            return unattributedTunnelAppKey
        }
        let info = getAppInfo(pid: pid, name: name)
        if let bundleId = info?.bundleIdentifier, !bundleId.isEmpty {
            return bundleId
        }
        return displayName
    }

    public var displayName: String {
        if name == unattributedTunnelProcessLabel {
            return unattributedTunnelProcessLabel
        }
        let info = getAppInfo(pid: pid, name: name)
        return info?.name ?? name
    }
}
