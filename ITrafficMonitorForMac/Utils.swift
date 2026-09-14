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

private let processOutputQueue = DispatchQueue(
    label: "itraffic.process-output",
    qos: .utility
)
private let defaultProcessOutputLimit = 8 * 1024 * 1024
private let processOutputReadBufferSize = 16 * 1024

/// One serial context owns one short-lived helper process from spawn through
/// cleanup. In particular, this never creates a detached `waitUntilExit()`
/// waiter or a blocking EOF reader per invocation.
private final class ProcessOutputContext {
    private enum Failure {
        case spawn
        case timedOut
        case outputLimit
        case read
    }

    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let completed = DispatchSemaphore(value: 0)

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stdoutReadHandle: FileHandle?
    private var stdoutWriteHandle: FileHandle?
    private var stdoutReadSource: DispatchSourceRead?
    private var timeoutWork: DispatchWorkItem?
    private var forceKillWork: DispatchWorkItem?
    private var finishWork: DispatchWorkItem?

    private var output = Data()
    private var failure: Failure?
    private var processExited = false
    private var stdoutClosed = false
    private var terminationRequested = false
    private var finished = false
    private var result: String?

    init(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = max(0, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
    }

    func wait() -> String? {
        processOutputQueue.async { [self] in start() }
        completed.wait()
        return result
    }

    private func start() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        process = task
        stdoutPipe = pipe
        stdoutReadHandle = readHandle
        stdoutWriteHandle = writeHandle

        task.terminationHandler = { [weak self] _ in
            processOutputQueue.async { [weak self] in
                self?.handleTermination()
            }
        }

        do {
            try task.run()
        } catch {
            failure = .spawn
            finish(nil)
            return
        }

        // The parent must close its copy of the write end immediately after
        // spawning. Otherwise the reader never observes EOF after a normal
        // child exit because the parent itself still owns a writer.
        try? writeHandle.close()

        guard makeReadSource(for: readHandle) else {
            failure = .read
            requestTermination()
            return
        }

        scheduleTimeout()
    }

    private func makeReadSource(for handle: FileHandle) -> Bool {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return false
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: processOutputQueue
        )
        source.setEventHandler { [weak self] in
            self?.drainAvailableOutput()
        }
        // The FileHandle owns the descriptor. Cancel the source first, then
        // close the handle exactly once during finish.
        source.setCancelHandler {}
        stdoutReadSource = source
        source.resume()
        return true
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.failure = .timedOut
            self.requestTermination()
        }
        timeoutWork = work
        processOutputQueue.asyncAfter(
            deadline: .now() + timeout,
            execute: work
        )
    }

    private func handleTermination() {
        guard !finished else { return }
        processExited = true

        if failure != nil {
            finish(nil)
            return
        }

        // Drain bytes already waiting in the non-blocking pipe before deciding
        // whether the normal completion path is safe to return.
        drainAvailableOutput()
        guard !finished else { return }
        if failure != nil {
            finish(nil)
        } else if stdoutClosed {
            finish(String(data: output, encoding: .utf8))
        } else {
            // A descendant may have inherited stdout. Do not wait forever for
            // its EOF or return a potentially truncated result.
            scheduleFinishAfterGrace()
        }
    }

    private func scheduleFinishAfterGrace() {
        guard finishWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(nil)
        }
        finishWork = work
        processOutputQueue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func drainAvailableOutput() {
        guard !finished, !stdoutClosed,
              let handle = stdoutReadHandle else { return }

        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: processOutputReadBufferSize)

        while !finished && !stdoutClosed {
            let count = buffer.withUnsafeMutableBytes { storage -> Int in
                guard let baseAddress = storage.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, storage.count)
            }

            if count > 0 {
                guard output.count <= maximumOutputBytes - count else {
                    failure = .outputLimit
                    requestTermination()
                    return
                }
                output.append(contentsOf: buffer[0..<count])
                continue
            }

            if count == 0 {
                stdoutClosed = true
                cancelReadSource()
                break
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }

            failure = .read
            requestTermination()
            return
        }

        if processExited && !finished {
            if failure != nil {
                finish(nil)
            } else if stdoutClosed {
                finish(String(data: output, encoding: .utf8))
            }
        }
    }

    private func requestTermination() {
        guard !finished, !terminationRequested else { return }
        terminationRequested = true

        sendSignal(SIGTERM)

        let forceKill = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.sendSignal(SIGKILL)
        }
        forceKillWork = forceKill
        processOutputQueue.asyncAfter(deadline: .now() + 0.25, execute: forceKill)

        // The termination callback normally finishes the context. This final
        // bounded fallback handles a broken child or an unusual Process state
        // without leaving the caller blocked forever.
        let finish = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(nil)
        }
        finishWork = finish
        processOutputQueue.asyncAfter(deadline: .now() + 1.25, execute: finish)
    }

    private func sendSignal(_ signal: Int32) {
        guard let pid = process?.processIdentifier, pid > 0 else { return }
        // Calling kill with pid 0 would signal the entire process group. The
        // positive-pid guard keeps timeout cleanup scoped to the helper.
        _ = Darwin.kill(pid, signal)
    }

    private func cancelReadSource() {
        guard let source = stdoutReadSource else { return }
        source.setEventHandler {}
        source.cancel()
        stdoutReadSource = nil
    }

    private func closeOutputHandles() {
        cancelReadSource()
        try? stdoutReadHandle?.close()
        try? stdoutWriteHandle?.close()
        stdoutReadHandle = nil
        stdoutWriteHandle = nil
        stdoutPipe = nil
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true

        timeoutWork?.cancel()
        forceKillWork?.cancel()
        finishWork?.cancel()
        timeoutWork = nil
        forceKillWork = nil
        finishWork = nil

        process?.terminationHandler = nil
        closeOutputHandles()
        process = nil

        result = failure == nil ? value : nil
        completed.signal()
    }
}

/// Runs a short-lived helper binary and returns its stdout, or nil if it could
/// not be spawned, exceeded `timeout`, encountered a read error, or produced
/// more than `maximumOutputBytes`.
///
/// The process deadline is tied to process termination rather than stdout EOF.
/// The parent write end is closed immediately after spawn, and all output is
/// consumed through a non-blocking DispatchSource so normal completion and
/// timeout completion both release every Pipe descriptor.
func runProcessCollectingOutput(
    executable: String,
    arguments: [String],
    timeout: TimeInterval = 3,
    maximumOutputBytes: Int = defaultProcessOutputLimit
) -> String? {
    ProcessOutputContext(
        executable: executable,
        arguments: arguments,
        timeout: timeout,
        maximumOutputBytes: maximumOutputBytes
    ).wait()
}

/// Waits for an already-running process to exit using its termination callback,
/// terminating (then SIGKILLing) it if it overruns `timeout`. Returns true when
/// it exited on its own. This is used only during nettop shutdown; it still
/// avoids creating a permanent `waitUntilExit()` waiter.
@discardableResult
func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let exited = DispatchSemaphore(value: 0)
    let previousHandler = process.terminationHandler
    process.terminationHandler = { task in
        previousHandler?(task)
        exited.signal()
    }

    defer { process.terminationHandler = nil }

    guard process.isRunning else { return true }
    if exited.wait(timeout: .now() + max(0, timeout)) == .success {
        return true
    }

    func sendSignal(_ signal: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, signal)
    }

    sendSignal(SIGTERM)
    if exited.wait(timeout: .now() + 1) == .success {
        return false
    }

    sendSignal(SIGKILL)
    _ = exited.wait(timeout: .now() + 1)
    return false
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

/// Process start time (epoch seconds) via sysctl. Used to validate pid-keyed
/// caches: macOS recycles pids, so a start-time mismatch means the cached
/// entry belongs to a previous process. Returns nil when the process is gone.
func processStartTime(of pid: Int) -> Int64? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
    let result = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
        sysctl(ptr.baseAddress, UInt32(ptr.count), &info, &size, nil, 0)
    }
    guard result == 0, size > 0 else { return nil }
    return Int64(info.kp_proc.p_starttime.tv_sec)
}

// Note: previous versions did manual `lockFocus`/`draw` rasterisation
// to a fixed pixel size — that rendered at 1x on Retina displays.
// All scaling is now done by SwiftUI via `.resizable().interpolation(.high)`.
