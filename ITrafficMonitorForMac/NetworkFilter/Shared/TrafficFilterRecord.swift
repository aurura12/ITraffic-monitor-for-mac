import Foundation

struct TrafficFilterRecord: Codable, Equatable {
    let schemaVersion: Int
    let sequence: Int64
    let timestamp: Int64
    let appKey: String
    let displayName: String
    let inBytes: Int64
    let outBytes: Int64
    let flowCount: Int
}
