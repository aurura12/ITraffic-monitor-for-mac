//
//  FreeAttributionCalibrator.swift
//  ITrafficMonitorForMac
//

import Foundation

enum FreeAttributionConfidence: Equatable {
    case noReference
    case matched
    case calibratedWithUnattributed
    case referenceMismatch
}

struct FreeAttributionCalibration {
    let entities: [ProcessEntity]
    let confidence: FreeAttributionConfidence
    let positiveGap: UTunTrafficCounters
}

func calibrateFreeAttribution(
    entities: [ProcessEntity],
    reference: UTunTrafficCounters?
) -> FreeAttributionCalibration {
    guard let reference else {
        return FreeAttributionCalibration(
            entities: entities,
            confidence: .noReference,
            positiveGap: UTunTrafficCounters(inBytes: 0, outBytes: 0)
        )
    }

    let attributedIn = entities.reduce(0) { $0 + max(0, $1.inBytes) }
    let attributedOut = entities.reduce(0) { $0 + max(0, $1.outBytes) }
    guard reference.inBytes >= attributedIn, reference.outBytes >= attributedOut else {
        return FreeAttributionCalibration(
            entities: entities,
            confidence: .referenceMismatch,
            positiveGap: UTunTrafficCounters(inBytes: 0, outBytes: 0)
        )
    }

    let gap = UTunTrafficCounters(
        inBytes: reference.inBytes - attributedIn,
        outBytes: reference.outBytes - attributedOut
    )
    guard gap.inBytes > 0 || gap.outBytes > 0 else {
        return FreeAttributionCalibration(entities: entities, confidence: .matched, positiveGap: gap)
    }

    var result = entities
    if let index = result.firstIndex(where: { $0.name == "Unattributed VPN" }) {
        result[index].inBytes += gap.inBytes
        result[index].outBytes += gap.outBytes
    } else {
        result.append(ProcessEntity(
            pid: 0,
            name: "Unattributed VPN",
            inBytes: gap.inBytes,
            outBytes: gap.outBytes
        ))
    }
    return FreeAttributionCalibration(
        entities: result,
        confidence: .calibratedWithUnattributed,
        positiveGap: gap
    )
}
