import Foundation
import NetworkExtension
import Combine

enum TrafficFilterState: Equatable {
    case disabled
    case authorizing
    case enabled
    case fallback
    case error(String)
}

final class TrafficFilterManager: ObservableObject {
    @Published private(set) var state: TrafficFilterState = .disabled
    @Published private(set) var lastReportDate: Date?
    @Published private(set) var identifiedAppCount = 0

    private let manager = NEFilterManager.shared()
    private var statsStore: TrafficFilterStatsStore?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "itraffic.filter-manager", qos: .utility)
    private var consumedSequence: Int64 = 0

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.statsStore = try TrafficFilterStatsStore()
            } catch {
                self.publish(.fallback)
                return
            }
            self.loadAndEnable()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func reloadStatus() {
        queue.async { [weak self] in self?.loadAndEnable() }
    }

    private func loadAndEnable() {
        publish(.authorizing)
        manager.loadFromPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                self.publish(.error(error.localizedDescription))
                return
            }

            let configuration = NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterPackets = false
            configuration.filterDataProviderBundleIdentifier =
                "com.foamzou.ITrafficMonitorForMac.TrafficFilterDataProvider"
            configuration.organization = "iTraffic"
            configuration.username = NSUserName()

            self.manager.localizedDescription = "iTraffic Network Traffic Statistics"
            self.manager.providerConfiguration = configuration
            self.manager.isEnabled = true
            self.manager.saveToPreferences { [weak self] error in
                guard let self else { return }
                if let error {
                    self.publish(.error(error.localizedDescription))
                    return
                }
                self.publish(.enabled)
                self.startPolling()
            }
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in self?.consumeRecords() }
        self.timer = timer
        timer.resume()
    }

    private func consumeRecords() {
        guard let statsStore else { return }
        do {
            let records = try statsStore.readNewRecords()
            guard !records.isEmpty else { return }
            let lastSequence = records.last?.sequence ?? consumedSequence
            // The extension stream is identity/status data only. nettop is the
            // sole historical byte source, so consuming these records must not
            // create a second set of traffic samples.
            try statsStore.markConsumedThrough(sequence: lastSequence)
            consumedSequence = lastSequence
            let apps = Set(records.map(\.appKey)).count
            publishReport(date: Date(), appCount: apps)
        } catch {
            publish(.fallback)
        }
    }

    private func publish(_ newState: TrafficFilterState) {
        DispatchQueue.main.async { [weak self] in self?.state = newState }
    }

    private func publishReport(date: Date, appCount: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.lastReportDate = date
            self?.identifiedAppCount = appCount
        }
    }
}
