import Foundation

enum TrafficFilterSharedOutput {
    static let appGroupIdentifier = "group.com.foamzou.ITrafficMonitorForMac"
    static let recordsFileName = "traffic-filter-records.jsonl"

    static func recordsURL(fileManager: FileManager = .default) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(recordsFileName)
    }

    static func append(
        _ records: [TrafficFilterRecord],
        fileManager: FileManager = .default
    ) throws {
        guard !records.isEmpty, let url = recordsURL(fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile)
        }

        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var data = fileManager.fileExists(atPath: url.path)
            ? try Data(contentsOf: url)
            : Data()
        let encoder = JSONEncoder()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }

        let temporaryURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(".traffic-filter-records-\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }
}
