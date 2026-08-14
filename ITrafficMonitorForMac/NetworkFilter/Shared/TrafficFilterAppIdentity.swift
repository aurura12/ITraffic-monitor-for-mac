import Foundation

let unattributedTrafficAppKey = "Unattributed VPN"

func normalizedTrafficAppKey(sourceAppIdentifier: String?) -> String {
    guard let sourceAppIdentifier,
          !sourceAppIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return unattributedTrafficAppKey
    }
    return sourceAppIdentifier
}
