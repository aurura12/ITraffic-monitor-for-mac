import Foundation

struct ReportInput: Equatable {
    let appKey: String
    let displayName: String
    let inBytes: Int64
    let outBytes: Int64
}

struct TrafficFilterReportAccumulator {
    private var aggregate = TrafficFilterAggregate()

    mutating func consume(_ input: ReportInput) {
        aggregate.add(
            appKey: normalizedTrafficAppKey(sourceAppIdentifier: input.appKey),
            displayName: input.displayName,
            inBytes: input.inBytes,
            outBytes: input.outBytes
        )
    }

    mutating func flush(timestamp: Int64, startingSequence: Int64) -> [TrafficFilterRecord] {
        aggregate.flush(timestamp: timestamp, startingSequence: startingSequence)
    }
}
