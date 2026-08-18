import Foundation

/// Traffic that could not be attributed to a real app is credited to the
/// proxy process. Clash is the "no source found" bucket — there is no
/// separate unattributed-VPN category.
let fallbackTrafficAppKey = "Clash Verge"

func normalizedTrafficAppKey(sourceAppIdentifier: String?) -> String {
    guard let sourceAppIdentifier,
          !sourceAppIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return fallbackTrafficAppKey
    }
    return sourceAppIdentifier
}
