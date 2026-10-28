//
//  NettopRunner.swift
//  ITrafficMonitorForMac
//
//  Direct Swift driver for /usr/bin/nettop. Replaces the bundled
//  Go `nettop-line` helper, removing the need for an extra binary
//  in the app bundle (and the x86_64-only architecture restriction).
//
//  Two non-obvious mitigations are required to keep nettop from
//  spinning CPU at 100% (replicated from foamzou/nettop-line):
//    1. Wrap nettop in `/usr/bin/script -q /dev/null` so it sees a
//       pseudo-TTY — without a TTY, nettop's TUI loop burns CPU.
//    2. Keep stdin open for the lifetime of the subprocess. nettop
//       polls stdin for keypresses (q to quit); a closed stdin
//       triggers a busy poll loop. We retain the Pipe but never
//       write or close it.
//

import Foundation

/// First restart delay. A crash loop doubles from here instead of hammering
/// the system once every 0.5 s forever.
let nettopRestartInitialDelay: TimeInterval = 0.5

/// Upper bound for the backoff: a nettop that keeps failing is retried twice a
/// minute, which is cheap enough to stay self-healing after a system update
/// re-enables it.
let nettopRestartMaximumDelay: TimeInterval = 30

/// Consecutive failed spawns/exits after which sampling is reported as failed
/// instead of merely restarting. Retries continue at the capped delay.
let nettopRestartFailureThreshold = 4

/// Delay before the next spawn attempt, given how many attempts in a row have
/// already failed (0 = the first retry). Exposed at file scope so the backoff
/// curve is testable without spawning a process.
func nettopRestartDelay(consecutiveFailures: Int) -> TimeInterval {
    let doublings = max(0, consecutiveFailures)
    // Clamp the exponent so a long-running failure cannot overflow the math.
    let exponent = min(doublings, 16)
    return min(nettopRestartInitialDelay * pow(2, Double(exponent)), nettopRestartMaximumDelay)
}

final class NettopRunner {
    /// Called once per nettop refresh with one frame's CSV lines (header
    /// dropped) and the seconds elapsed since the previous flush.
    var onFrame: (([String], TimeInterval) -> Void)?
    /// Called when a running nettop process terminates and sampling may have a
    /// gap. The argument is the number of consecutive failed attempts so far,
    /// so the observer can distinguish "restarting" from "keeps failing".
    var onRestart: ((Int) -> Void)?

    private let interval: Int
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "nettop-runner", qos: .utility)

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var lineBuffer = Data()
    private var frameLines: [String] = []
    private var debounceWork: DispatchWorkItem?
    private var restartWork: DispatchWorkItem?
    private var droppedFirstFrame = false
    private var shouldRestart = false
    /// Consecutive spawn failures / unexpected exits since the last delivered
    /// frame. Reset by a frame (proof the process works) and by `start()`.
    /// Touched only on `queue`.
    private var consecutiveFailures = 0
    private var lastFrameAt: Date?
    private let processConfigurator: (Process, Int) -> Void

    init(
        interval: Int,
        // Frame boundary detection: nettop frames have no delimiter, so a
        // frame is flushed after this much read idle time. The value must
        // absorb stdout chunk gaps under load (a split frame would be
        // recorded as two partial samples) while staying well below the
        // sampling cadence so records are not delayed.
        debounceInterval: TimeInterval = 0.35,
        processConfigurator: @escaping (Process, Int) -> Void = { task, interval in
            task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            let nettopCommand = "/usr/bin/nettop -P -d -L 0 -J bytes_in,bytes_out -t external -s \(interval) -c"
            task.arguments = [
                "-q", "/dev/null",
                "/bin/sh", "-c", "exec \(nettopCommand)"
            ]
        }
    ) {
        self.interval = interval
        self.debounceInterval = debounceInterval
        self.processConfigurator = processConfigurator
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.restartWork?.cancel()
            self.restartWork = nil
            self.shouldRestart = true
            // An explicit start is a fresh attempt sequence: a user resume
            // should not inherit the previous crash loop's backoff.
            self.consecutiveFailures = 0
            guard self.process == nil || self.process?.isRunning == false else { return }
            self.spawn()
        }
    }

    func stop() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.shouldRestart = false
            self.restartWork?.cancel()
            self.restartWork = nil
            self.process?.terminationHandler = nil
            if let process = self.process, process.isRunning {
                process.terminate()
                // Bounded: a nettop that ignores SIGTERM must not hang quit,
                // which reaches here synchronously from applicationWillTerminate.
                waitForProcessExit(process, timeout: 1)
            }
            self.cleanupHandles()
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.process = nil
        }
    }

    private func spawn() {
        let task = Process()
        processConfigurator(task, interval)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        // CRITICAL: retain stdin pipe; nettop polls stdin and burns CPU if it's closed.
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Reset per-spawn state so each restart drops its own cumulative first frame.
        self.lineBuffer.removeAll(keepingCapacity: true)
        self.frameLines.removeAll(keepingCapacity: true)
        self.droppedFirstFrame = false
        self.lastFrameAt = nil

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.queue.async { self.consume(data) }
        }

        // Drain stderr. nettop/script error output is not parsed, but leaving
        // the pipe unread would let a chatty child fill the buffer and block.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        task.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.cleanupHandles()
                self.process = nil
                self.consecutiveFailures += 1
                self.onRestart?(self.consecutiveFailures)
                guard self.shouldRestart else { return }
                self.scheduleRestartAfterFailure()
            }
        }

        do {
            try task.run()
            self.process = task
        } catch {
            consecutiveFailures += 1
            Log.nettop.error("failed to spawn nettop: \(error.localizedDescription, privacy: .public)")
            if shouldRestart {
                scheduleRestartAfterFailure()
            }
        }
    }

    /// Back off before the next attempt, and say so once the failures are no
    /// longer a one-off. Runs on `queue`.
    private func scheduleRestartAfterFailure() {
        let delay = nettopRestartDelay(consecutiveFailures: consecutiveFailures)
        Log.nettop.error("nettop attempt \(self.consecutiveFailures, privacy: .public) failed; retrying in \(delay, privacy: .public)s")
        if consecutiveFailures == nettopRestartFailureThreshold {
            Log.nettop.error("nettop failed \(self.consecutiveFailures, privacy: .public) times in a row; sampling is reported as failed while retries continue")
        }
        scheduleRestart(after: delay)
    }

    private func scheduleRestart(after delay: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRestart else { return }
            self.restartWork = nil
            self.spawn()
        }
        restartWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            let line = String(data: lineData, encoding: .utf8) ?? ""
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                frameLines.append(trimmed)
            }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushFrame() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func flushFrame() {
        guard !frameLines.isEmpty else { return }
        let frame = frameLines
        frameLines.removeAll(keepingCapacity: true)

        // A delivered frame proves the process works: end the failure streak
        // so the next restart starts again from the initial delay.
        if consecutiveFailures > 0 {
            Log.nettop.notice("nettop sampling recovered after \(self.consecutiveFailures, privacy: .public) failed attempts")
            consecutiveFailures = 0
        }

        let now = Date()
        let measured = lastFrameAt.map { now.timeIntervalSince($0) } ?? Double(interval)
        lastFrameAt = now
        // Frames are nominally `interval` seconds apart, but the read-idle
        // debounce can merge or split them. Allow a 2x swing before clamping
        // so a burst or a stalled read cannot skew the reported rate.
        let seconds = min(max(measured, Double(interval) / 2), Double(interval) * 2)

        // First frame after spawn contains cumulative-since-boot values, not delta.
        guard droppedFirstFrame else {
            droppedFirstFrame = true
            return
        }
        onFrame?(frame, seconds)
    }

    private func cleanupHandles() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        debounceWork?.cancel()
        debounceWork = nil
    }
}
