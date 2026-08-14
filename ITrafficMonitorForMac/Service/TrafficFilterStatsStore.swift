import Foundation

final class TrafficFilterStatsStore {
    private let fileManager: FileManager
    private let directory: URL
    private let recordsURL: URL
    private let cursorURL: URL

    init(
        directory: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TrafficFilterSharedOutput.appGroupIdentifier
        ),
        fileManager: FileManager = .default
    ) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        self.directory = directory
        self.fileManager = fileManager
        self.recordsURL = directory.appendingPathComponent(TrafficFilterSharedOutput.recordsFileName)
        self.cursorURL = directory.appendingPathComponent("traffic-filter-consumed-sequence")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func readNewRecords() throws -> [TrafficFilterRecord] {
        guard fileManager.fileExists(atPath: recordsURL.path) else { return [] }
        let data = try Data(contentsOf: recordsURL)
        let lastSequence = try readLastSequence()
        let decoder = JSONDecoder()
        var records: [TrafficFilterRecord] = []

        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(TrafficFilterRecord.self, from: Data(lineData)) else {
                break
            }
            if record.sequence > lastSequence {
                records.append(record)
            }
        }
        return records.sorted { $0.sequence < $1.sequence }
    }

    func markConsumedThrough(sequence: Int64) throws {
        try String(sequence).data(using: .utf8)?.write(to: cursorURL, options: .atomic)
    }

    func write(records: [TrafficFilterRecord]) throws {
        guard !records.isEmpty else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = fileManager.fileExists(atPath: recordsURL.path)
            ? try Data(contentsOf: recordsURL)
            : Data()
        let encoder = JSONEncoder()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: recordsURL, options: .atomic)
    }

    private func readLastSequence() throws -> Int64 {
        guard let data = fileManager.contents(atPath: cursorURL.path),
              let text = String(data: data, encoding: .utf8),
              let sequence = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return sequence
    }
}
