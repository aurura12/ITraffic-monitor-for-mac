//
//  Utils.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import Foundation
import Cocoa
import Darwin

/// Process-level launch environment.
enum AppEnvironment {
    /// True when this process is a unit/UI-test host rather than a normal app
    /// launch. Hosted tests run inside the app process, so without this guard
    /// `applicationDidFinishLaunching` would start `nettop` and construct the
    /// default `TrafficRecorder`, writing the test machine's real traffic into
    /// the user's history. Detected from the XCTest runtime: the runner injects
    /// the test bundle and sets its environment variables.
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()
}

func formatBytes(bytes: Int) -> String {
    let kbyte = Float(bytes) / 1024
    if kbyte <= 0 {
        return "0 KB/s"
    }
    if kbyte < 1024 {
        return String(format:"%.1f KB/s", kbyte)
    }
    let mbyte = kbyte / 1024
    if mbyte < 1024 {
        return String(format:"%.1f MB/s", mbyte)
    }
    return String(format:"%.1f GB/s", mbyte / 1024)
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
