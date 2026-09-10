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

final class NettopRunner {
    /// Called once per nettop refresh with one frame's CSV lines (header dropped).
    var onFrame: (([String]) -> Void)?
    /// Called when a running nettop process terminates and sampling may have a gap.
    var onRestart: (() -> Void)?

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
                self.onRestart?()
                guard self.shouldRestart else { return }
                self.scheduleRestart(after: 0.5)
            }
        }

        do {
            try task.run()
            self.process = task
        } catch {
            print("[NettopRunner] failed to spawn: \(error)")
            if shouldRestart {
                scheduleRestart(after: 1.0)
            }
        }
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

        // First frame after spawn contains cumulative-since-boot values, not delta.
        guard droppedFirstFrame else {
            droppedFirstFrame = true
            return
        }
        onFrame?(frame)
    }

    private func cleanupHandles() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        debounceWork?.cancel()
        debounceWork = nil
    }
}
