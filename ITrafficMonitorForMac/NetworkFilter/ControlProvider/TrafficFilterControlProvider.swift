import NetworkExtension

final class TrafficFilterControlProvider: NEFilterControlProvider {
    private let queue = DispatchQueue(label: "itraffic.filter-control")
    private var timer: DispatchSourceTimer?
    private var accumulator = TrafficFilterReportAccumulator()
    private var nextSequence: Int64 = 1

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.flush() }
            self.timer = timer
            timer.resume()
            completionHandler(nil)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.flush()
            completionHandler()
        }
    }

    override func handle(_ report: NEFilterReport) {
        queue.async { [weak self] in
            guard let self else { return }
            let appKey = normalizedTrafficAppKey(
                sourceAppIdentifier: report.flow?.sourceAppIdentifier
            )
            self.accumulator.consume(ReportInput(
                appKey: appKey,
                displayName: appKey,
                inBytes: Int64(max(0, report.bytesInboundCount)),
                outBytes: Int64(max(0, report.bytesOutboundCount))
            ))
        }
    }

    private func flush() {
        let records = accumulator.flush(
            timestamp: Int64(Date().timeIntervalSince1970),
            startingSequence: nextSequence
        )
        guard !records.isEmpty else { return }
        nextSequence = (records.last?.sequence ?? nextSequence - 1) + 1
        try? TrafficFilterSharedOutput.append(records)
    }
}
