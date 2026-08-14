import Foundation

private struct TrafficFilterAggregateEntry {
    let appKey: String
    var displayName: String
    var inBytes: Int64
    var outBytes: Int64
    var flowCount: Int
}

struct TrafficFilterAggregate {
    private var entries: [String: TrafficFilterAggregateEntry] = [:]

    mutating func add(
        appKey: String,
        displayName: String,
        inBytes: Int64,
        outBytes: Int64
    ) {
        let inBytes = max(0, inBytes)
        let outBytes = max(0, outBytes)
        guard inBytes > 0 || outBytes > 0 else { return }

        if var entry = entries[appKey] {
            entry.inBytes += inBytes
            entry.outBytes += outBytes
            entry.flowCount += 1
            if entry.displayName.isEmpty, !displayName.isEmpty {
                entry.displayName = displayName
            }
            entries[appKey] = entry
        } else {
            entries[appKey] = TrafficFilterAggregateEntry(
                appKey: appKey,
                displayName: displayName,
                inBytes: inBytes,
                outBytes: outBytes,
                flowCount: 1
            )
        }
    }

    mutating func flush(timestamp: Int64, startingSequence: Int64) -> [TrafficFilterRecord] {
        let sortedEntries = entries.values.sorted { $0.appKey < $1.appKey }
        entries.removeAll(keepingCapacity: true)

        return sortedEntries.enumerated().map { offset, entry in
            TrafficFilterRecord(
                schemaVersion: 1,
                sequence: startingSequence + Int64(offset),
                timestamp: timestamp,
                appKey: entry.appKey,
                displayName: entry.displayName,
                inBytes: entry.inBytes,
                outBytes: entry.outBytes,
                flowCount: entry.flowCount
            )
        }
    }
}

struct TrafficFilterSequenceConsumer {
    private(set) var lastSequence: Int64

    init(lastSequence: Int64 = 0) {
        self.lastSequence = lastSequence
    }

    mutating func consume(_ records: [TrafficFilterRecord]) -> [TrafficFilterRecord] {
        let newRecords = records
            .filter { $0.sequence > lastSequence }
            .sorted { $0.sequence < $1.sequence }
        guard let last = newRecords.last else { return [] }
        lastSequence = last.sequence
        return newRecords
    }
}
