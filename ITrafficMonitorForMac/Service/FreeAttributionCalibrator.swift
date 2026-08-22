//
//  FreeAttributionCalibrator.swift
//  ITrafficMonitorForMac
//

import Foundation

enum FreeAttributionConfidence: Equatable {
    case noReference
    case matched
    case calibratedWithProxyFallback
    case referenceMismatch
}

struct FreeAttributionCalibration {
    let entities: [ProcessEntity]
    let confidence: FreeAttributionConfidence
    let positiveGap: UTunTrafficCounters
}

/// Distribute the unattributed tunnel bytes across the apps that are actively
/// moving traffic, weighted by each app's own bytes.
///
/// The unattributed pool is the utun reference gap (bytes the tunnel moved that
/// no nettop entity explains) plus any bytes the proxy attribution already left
/// on the "Clash Verge" fallback row. Both are real tunnel traffic that belongs
/// to the apps behind the proxy, so instead of parking the whole pool on the
/// fallback bucket we split it among the active apps in proportion to their own
/// in/out traffic. The Clash Verge row is zeroed once the pool has been moved.
///
/// The fallback to Clash Verge only survives when there is no active app that
/// could plausibly own the bytes (e.g. the frame contains only the proxy row).
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

    let clashIndex = entities.firstIndex { $0.name == "Clash Verge" }
    let poolIn = gap.inBytes + (clashIndex.map { max(0, entities[$0].inBytes) } ?? 0)
    let poolOut = gap.outBytes + (clashIndex.map { max(0, entities[$0].outBytes) } ?? 0)
    guard poolIn > 0 || poolOut > 0 else {
        return FreeAttributionCalibration(entities: entities, confidence: .matched, positiveGap: gap)
    }

    // Recipients: every entity carrying traffic, excluding the fallback row.
    let active = entities.enumerated().filter { index, entity in
        index != clashIndex && (entity.inBytes > 0 || entity.outBytes > 0)
    }
    let totalIn = active.reduce(0) { $0 + max(0, $1.element.inBytes) }
    let totalOut = active.reduce(0) { $0 + max(0, $1.element.outBytes) }

    // No active app that could own the bytes: keep the conservative fallback
    // and park the gap on Clash Verge instead of inventing a source.
    guard !active.isEmpty else {
        var result = entities
        if let index = clashIndex {
            result[index].inBytes += gap.inBytes
            result[index].outBytes += gap.outBytes
        } else {
            result.append(ProcessEntity(pid: 0, name: "Clash Verge", inBytes: gap.inBytes, outBytes: gap.outBytes))
        }
        return FreeAttributionCalibration(
            entities: result,
            confidence: .calibratedWithProxyFallback,
            positiveGap: gap
        )
    }

    var result = entities
    var distributedIn = 0
    var distributedOut = 0
    if totalIn > 0 {
        for (index, entity) in active where entity.inBytes > 0 {
            let share = Int((Double(poolIn) * Double(entity.inBytes)) / Double(totalIn))
            result[index].inBytes += share
            distributedIn += share
        }
        // Integer rounding can leave a few bytes undistributed; give them to the
        // largest in-direction app so the pool is fully absorbed.
        let leftover = poolIn - distributedIn
        if leftover > 0,
           let largest = active.filter({ $0.element.inBytes > 0 })
               .max(by: { $0.element.inBytes < $1.element.inBytes }) {
            result[largest.offset].inBytes += leftover
            distributedIn += leftover
        }
    }
    if totalOut > 0 {
        for (index, entity) in active where entity.outBytes > 0 {
            let share = Int((Double(poolOut) * Double(entity.outBytes)) / Double(totalOut))
            result[index].outBytes += share
            distributedOut += share
        }
        let leftover = poolOut - distributedOut
        if leftover > 0,
           let largest = active.filter({ $0.element.outBytes > 0 })
               .max(by: { $0.element.outBytes < $1.element.outBytes }) {
            result[largest.offset].outBytes += leftover
            distributedOut += leftover
        }
    }

    // The fallback row keeps whatever could not be distributed (e.g. an
    // upload-only gap when no active app uploaded); once it is empty it is
    // dropped from the frame so it does not show up as a zero-bucket app.
    if let index = clashIndex {
        result[index].inBytes = poolIn - distributedIn
        result[index].outBytes = poolOut - distributedOut
        if result[index].inBytes == 0, result[index].outBytes == 0 {
            result.remove(at: index)
        }
    }
    return FreeAttributionCalibration(
        entities: result,
        confidence: .calibratedWithProxyFallback,
        positiveGap: gap
    )
}
