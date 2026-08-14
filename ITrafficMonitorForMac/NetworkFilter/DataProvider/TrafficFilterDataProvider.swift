import NetworkExtension

final class TrafficFilterDataProvider: NEFilterDataProvider {
    private var appKeyByFlowID: [String: String] = [:]

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        appKeyByFlowID.removeAll(keepingCapacity: true)
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        appKeyByFlowID.removeAll(keepingCapacity: false)
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        appKeyByFlowID[flow.identifier] = normalizedTrafficAppKey(
            sourceAppIdentifier: flow.sourceAppIdentifier
        )
        let verdict = NEFilterNewFlowVerdict.allow()
        verdict.shouldReport = true
        verdict.statisticsReportFrequency = .high
        return verdict
    }

    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        appKeyByFlowID[flow.identifier] = nil
        return .allow()
    }

    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        appKeyByFlowID[flow.identifier] = nil
        return .allow()
    }
}
