//
//  FreeAttributionCalibrator.swift
//  ITrafficMonitorForMac
//

import Foundation

/// Compatibility result for callers from older builds.
///
/// Free attribution is intentionally disabled: nettop is the sole byte source,
/// and no utun/reference gap may be turned into app traffic. Production code
/// does not call this function; it remains only so an older integration can
/// fail closed after an update.
enum FreeAttributionConfidence: Equatable {
    case noReference
}

struct FreeAttributionCalibration {
    let entities: [ProcessEntity]
    let confidence: FreeAttributionConfidence
    let positiveGap: UTunTrafficCounters
}

@available(*, deprecated, message: "Free attribution is disabled; use nettop raw entities and same-frame proxy settlement.")
func calibrateFreeAttribution(
    entities: [ProcessEntity],
    reference: UTunTrafficCounters?
) -> FreeAttributionCalibration {
    FreeAttributionCalibration(
        entities: entities,
        confidence: .noReference,
        positiveGap: UTunTrafficCounters(inBytes: 0, outBytes: 0)
    )
}
