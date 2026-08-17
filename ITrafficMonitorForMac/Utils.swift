//
//  Utils.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import Foundation
import Cocoa
import Darwin

func formatBytes(bytes: Int) -> String {
    let kbyte = Float(bytes) / 1024
    if kbyte <= 0 {
        return "0 KB/s"
    }
    if kbyte < 1024 {
        return String(format:"%.1f KB/s", kbyte)
    }
    return String(format:"%.1f MB/s", kbyte / 1024)
}

/// Total-bytes formatter (no rate suffix): "512 B", "12.3 KB", "1.2 MB", "3.4 GB".
func formatBytesTotal(bytes: Int) -> String {
    let b = Double(bytes)
    let kb = b / 1024
    if kb < 1 { return String(format: "%d B", bytes) }
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    let mb = kb / 1024
    if mb < 1024 { return String(format: "%.1f MB", mb) }
    let gb = mb / 1024
    if gb < 1024 { return String(format: "%.2f GB", gb) }
    return String(format: "%.2f TB", gb / 1024)
}

/// Local epoch-day basis: local midnight of 1970-01-01. Consistent with
/// `dayIndex(for:calendar:)` so stored `day` values round-trip exactly.
private let epochDayZero = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 0))

/// Local epoch-day index (local days since 1970-01-01) for a date.
/// Truncating `startOfDay.timeIntervalSince1970 / 86400` is off by a day for
/// negative-offset timezones, so compute the whole-day difference via Calendar.
func dayIndex(for date: Date, calendar: Calendar) -> Int {
    let dayZero = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
    return calendar.dateComponents([.day], from: dayZero, to: calendar.startOfDay(for: date)).day ?? 0
}

/// Local midnight Date for a `day` value stored in the DB.
func dateFromDay(_ day: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: day, to: epochDayZero)
        ?? Date(timeIntervalSince1970: TimeInterval(day) * 86400)
}

/// Best-effort app icon for a history `app_key`. Bundle identifiers can be
/// resolved via LaunchServices; display-name keys (e.g. "iTerm2 · node")
/// have no bundle, so they fall back to the blank placeholder.
/// Results are cached (including the blank fallback) so the 200-row Apps
/// list doesn't hit LaunchServices on every render.
private var iconCache: [String: NSImage] = [:]
private let iconCacheLock = NSLock()

func iconForAppKey(_ key: String) -> NSImage {
    iconCacheLock.lock()
    if let cached = iconCache[key] {
        iconCacheLock.unlock()
        return cached
    }
    iconCacheLock.unlock()

    let icon: NSImage
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
        icon = NSWorkspace.shared.icon(forFile: url.path)
    } else {
        icon = NSImage(named: "blank") ?? NSImage()
    }

    iconCacheLock.lock()
    iconCache[key] = icon
    iconCacheLock.unlock()
    return icon
}

/// Compact unit format for list rows: "55K", "9.1M", "1.2G", "—" for 0.
/// `/s` is dropped — sampling cadence is implicit in the list context.
func formatBytesCompact(bytes: Int) -> String {
    if bytes <= 0 { return "—" }
    let kb = Double(bytes) / 1024
    if kb < 0.05 { return "—" }
    if kb < 1000 {
        return kb < 10 ? String(format: "%.1fK", kb) : String(format: "%.0fK", kb)
    }
    let mb = kb / 1024
    if mb < 1000 {
        return mb < 10 ? String(format: "%.1fM", mb) : String(format: "%.0fM", mb)
    }
    let gb = mb / 1024
    return gb < 10 ? String(format: "%.1fG", gb) : String(format: "%.0fG", gb)
}

struct AppInfo {
    var icon: NSImage
    var name: String?
    var bundleIdentifier: String?
    var executablePath: String?
    var launchDate: Date?
    var updateTime: Int
}

var APP_INFO_CACHE = [Int: AppInfo]()
var CACHE_TTL = 3600
private let appInfoLock = NSLock()

/// Bundle identifier of the system WebKit network daemon. WKWebView-based
/// apps route their connections through this shared process, so the monitor
/// sees `com.apple.WebKit.Networking` instead of the owning app. Each host
/// app gets its own daemon instance, labeled "<AppName> Networking".
let webkitNetworkingBundleIdentifier = "com.apple.WebKit.Networking"
private let webkitNetworkingNameSuffix = " Networking"

private struct WebKitHostCacheEntry {
    let hostBundleId: String
    let hostName: String
    let daemonLaunchDate: Date?
    let updateTime: Int
}

private var webKitHostCache: [Int: WebKitHostCacheEntry] = [:]
private let webKitHostLock = NSLock()
private let webKitHostCacheTTL = 5

/// Resolve the host application for a `com.apple.WebKit.Networking` daemon
/// PID. macOS labels each daemon instance "<HostApp> Networking"; stripping
/// that suffix and matching a running application by localized name yields
/// the app that owns the WebKit traffic.
///
/// Returns nil for non-WebKit processes and when no running host app matches.
/// Results are cached per daemon PID (validated against the daemon's launch
/// date so a reused PID cannot hit a stale entry) for `webKitHostCacheTTL`
/// seconds. Thread-safe: called from the nettop queue and the recorder.
func webKitHostApp(forPID pid: Int) -> (bundleId: String, name: String)? {
    let timestamp = Int(NSDate().timeIntervalSince1970)

    guard let daemon = NSRunningApplication(processIdentifier: pid_t(pid)),
          daemon.bundleIdentifier == webkitNetworkingBundleIdentifier,
          let daemonName = daemon.localizedName,
          daemonName.hasSuffix(webkitNetworkingNameSuffix) else {
        return nil
    }
    let hostName = String(daemonName.dropLast(webkitNetworkingNameSuffix.count))
    guard !hostName.isEmpty else { return nil }
    let daemonLaunchDate = daemon.launchDate

    webKitHostLock.lock()
    if let cached = webKitHostCache[pid],
       cached.daemonLaunchDate == daemonLaunchDate,
       timestamp - cached.updateTime < webKitHostCacheTTL {
        webKitHostLock.unlock()
        return (cached.hostBundleId, cached.hostName)
    }
    webKitHostLock.unlock()

    guard let host = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == hostName
    }), let hostBundleId = host.bundleIdentifier, hostBundleId != webkitNetworkingBundleIdentifier else {
        return nil
    }
    let result = (hostBundleId, host.localizedName ?? hostName)

    webKitHostLock.lock()
    webKitHostCache[pid] = WebKitHostCacheEntry(
        hostBundleId: result.0,
        hostName: result.1,
        daemonLaunchDate: daemonLaunchDate,
        updateTime: timestamp
    )
    webKitHostLock.unlock()
    return result
}

/// Read a process's executable path. Works for daemons and helper processes
/// that `NSRunningApplication` does not expose (they are not registered apps).
func executablePath(ofPID pid: Int) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let size = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
    guard size > 0 else { return nil }
    return String(cString: buffer)
}

/// Return the top-level application bundle path for a process executable
/// path — the first ".app" directory component — or nil when the executable
/// does not live inside an app bundle. For a helper bundled inside another
/// app (e.g. `.../wpsoffice.app/Contents/SharedSupport/wpscloudsvr.app/...`)
/// this returns the outer app, which is the owning application.
func outermostAppBundlePath(in path: String) -> String? {
    var accumulated = ""
    for component in path.split(separator: "/").map(String.init) {
        accumulated += "/" + component
        if component.hasSuffix(".app") {
            return accumulated
        }
    }
    return nil
}

private struct OwningAppCacheEntry {
    let hostBundleId: String?
    let hostName: String?
    let launchDate: Date?
    let updateTime: Int
}

private var owningAppCache: [Int: OwningAppCacheEntry] = [:]
private let owningAppLock = NSLock()
private let owningAppCacheTTL = 5

private func runningApplicationName(bundleId: String) -> String? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }?.localizedName
}

/// Resolve the application that owns a helper / service / daemon process.
///
/// - WebKit networking daemons are labeled "<HostApp> Networking".
/// - Any process whose executable lives inside an app bundle belongs to the
///   top-level `.app` that contains it, unless that bundle is the process's
///   own (i.e. it is the application's main executable).
///
/// Returns `(hostBundleId, hostName)`, or nil when the process is not a
/// helper or no owning app is determinable. Results are cached per PID
/// (validated against the process's launch date) for `owningAppCacheTTL`
/// seconds. Thread-safe: called from the nettop queue and the recorder.
func owningAppForProcess(pid: Int, ownBundleId: String?, ownDisplayName: String?) -> (bundleId: String, name: String)? {
    let timestamp = Int(NSDate().timeIntervalSince1970)
    let launchDate = NSRunningApplication(processIdentifier: pid_t(pid))?.launchDate

    owningAppLock.lock()
    if let cached = owningAppCache[pid],
       cached.launchDate == launchDate,
       timestamp - cached.updateTime < owningAppCacheTTL {
        let result = cached.hostBundleId.map { ($0, cached.hostName ?? $0) }
        owningAppLock.unlock()
        return result
    }
    owningAppLock.unlock()

    let resolved: (bundleId: String, name: String)?
    if ownBundleId == webkitNetworkingBundleIdentifier {
        // WebKit daemons: the owning app appears in the "<HostApp> Networking"
        // label macOS assigns to the daemon process.
        resolved = webKitHostApp(forPID: pid)
    } else if let path = executablePath(ofPID: pid),
              let outerAppPath = outermostAppBundlePath(in: path),
              let outerBundleId = Bundle(path: outerAppPath)?.bundleIdentifier,
              outerBundleId != ownBundleId {
        // Helper binary bundled inside another app: attribute to the outer app.
        let hostName = runningApplicationName(bundleId: outerBundleId)
            ?? Bundle(path: outerAppPath)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(path: outerAppPath)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? (outerAppPath as NSString).lastPathComponent
        resolved = (outerBundleId, hostName)
    } else {
        resolved = nil
    }

    owningAppLock.lock()
    owningAppCache[pid] = OwningAppCacheEntry(
        hostBundleId: resolved?.bundleId,
        hostName: resolved?.name,
        launchDate: launchDate,
        updateTime: timestamp
    )
    owningAppLock.unlock()
    return resolved
}

/// Registry of helper-bundle-id -> owning-app-bundle-id mappings, populated
/// from the nettop path (which sees every process and can resolve the owning
/// app via its executable path). The Network Extension consumer consults it
/// to skip helper records that the nettop path records instead.
final class HelperAttributionRegistry {
    static let shared = HelperAttributionRegistry()

    private let lock = NSLock()
    private var helperToHost: [String: String] = [:]

    private init() {}

    /// Record `helperBundleId -> owningAppBundleId` for each helper entity.
    func register(entities: [ProcessEntity]) {
        lock.lock()
        for entity in entities where entity.isFilterUnattributableHelper {
            if let helperId = entity.ownBundleIdentifier {
                let hostId = entity.appKey
                if hostId != helperId {
                    helperToHost[helperId] = hostId
                }
            }
        }
        lock.unlock()
    }

    /// True when `bundleId` is a known helper whose bytes the nettop path
    /// records under the owning app.
    func isKnownHelper(_ bundleId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return helperToHost[bundleId] != nil
    }
}

func preferredDisplayName(applicationName: String?, processName: String, walkedToAncestor: Bool) -> String {
    guard let applicationName, !applicationName.isEmpty else {
        return processName
    }

    // Keep the list focused on applications. Helper and command-line child
    // processes inherit the display name of the application that owns them.
    // `walkedToAncestor` remains part of the resolver contract because it
    // describes how the application was found, but does not change display.
    _ = walkedToAncestor
    return applicationName
}

/// Resolve icon + display name for a PID:
/// 1. Try `NSRunningApplication(pid)` directly (GUI apps).
/// 2. If not found, walk the parent process tree up to 6 levels until
///    we hit something `NSRunningApplication` recognises — typically
///    the terminal / IDE that launched the CLI tool — and reuse its icon.
///    The display name uses the resolved application's localized name so
///    helper and child processes do not clutter the list.
/// Cached per-PID for `CACHE_TTL` seconds. Thread-safe: may be called
/// from both the main thread (list rows) and the nettop runner queue
/// (history recorder).
func getAppInfo(pid: Int, name: String) -> AppInfo? {
    let timestamp = Int(NSDate().timeIntervalSince1970)
    var resolvedApp = NSRunningApplication(processIdentifier: pid_t(pid))
    var walkedToAncestor = false

    if resolvedApp == nil {
        var current = pid
        for _ in 0..<6 {
            guard let pp = parentPid(of: current), pp > 1 else { break }
            current = pp
            if let app = NSRunningApplication(processIdentifier: pid_t(pp)) {
                resolvedApp = app
                walkedToAncestor = true
                break
            }
        }
    }

    // Validate the process identity before reusing a PID-keyed cache entry.
    // PIDs are reused by macOS, so a time-only cache can assign a new process
    // to the previous process's application.
    appInfoLock.lock()
    if let cached = APP_INFO_CACHE[pid],
       (timestamp - cached.updateTime) < CACHE_TTL,
       let resolvedApp,
       cached.executablePath == resolvedApp.executableURL?.path,
       cached.launchDate == resolvedApp.launchDate {
        appInfoLock.unlock()
        return cached
    }
    appInfoLock.unlock()

    // Keep the original NSImage (multi-rep, Retina-aware). Pre-
    // rasterising to a fixed pixel size via lockFocus produced soft
    // icons on 2x displays. SwiftUI's Image will downscale crisply
    // when given an unrasterised NSImage + `.interpolation(.high)`.
    let icon = resolvedApp?.icon ?? NSImage(named: "blank") ?? NSImage()
    let bundleIdentifier = resolvedApp?.bundleIdentifier

    let displayName = preferredDisplayName(
        applicationName: resolvedApp?.localizedName,
        processName: name,
        walkedToAncestor: walkedToAncestor
    )

    let info = AppInfo(
        icon: icon,
        name: displayName,
        bundleIdentifier: bundleIdentifier,
        executablePath: resolvedApp?.executableURL?.path,
        launchDate: resolvedApp?.launchDate,
        updateTime: timestamp
    )
    appInfoLock.lock()
    APP_INFO_CACHE[pid] = info
    appInfoLock.unlock()
    return info
}

/// Look up a process's parent PID via sysctl.
func parentPid(of pid: Int) -> Int? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
    let result = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
        sysctl(ptr.baseAddress, UInt32(ptr.count), &info, &size, nil, 0)
    }
    guard result == 0, size > 0 else { return nil }
    return Int(info.kp_eproc.e_ppid)
}

// Note: previous versions did manual `lockFocus`/`draw` rasterisation
// to a fixed pixel size — that rendered at 1x on Retina displays.
// All scaling is now done by SwiftUI via `.resizable().interpolation(.high)`.
