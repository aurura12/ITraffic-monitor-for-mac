import Foundation

enum TrafficTotalsStatus: Equatable {
    case withinTolerance
    case mismatch
    case insufficientData
}

struct TrafficTotalsReconciliation: Equatable {
    let status: TrafficTotalsStatus
    let difference: Int64
    let tolerance: Int64
}

func reconcileTrafficTotals(
    filterTotal: Int64,
    attributedTotal: Int64,
    unattributedTotal: Int64
) -> TrafficTotalsReconciliation {
    guard filterTotal >= 0, attributedTotal >= 0, unattributedTotal >= 0 else {
        return TrafficTotalsReconciliation(status: .insufficientData, difference: 0, tolerance: 0)
    }

    let expected = attributedTotal + unattributedTotal
    let difference = filterTotal - expected
    let larger = max(filterTotal, expected)
    let tolerance = 64 * 1024 + larger / 50
    let status: TrafficTotalsStatus = abs(difference) <= tolerance ? .withinTolerance : .mismatch
    return TrafficTotalsReconciliation(status: status, difference: difference, tolerance: tolerance)
}
