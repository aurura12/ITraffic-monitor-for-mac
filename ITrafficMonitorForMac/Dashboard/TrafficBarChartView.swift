//
//  TrafficBarChartView.swift
//  ITrafficMonitorForMac
//
//  Horizontal usage bar chart: total traffic per day / month / quarter /
//  year. Supports linear and log X scales, and vertical scrolling when the
//  number of bars exceeds the visible window.
//
//  Drawn entirely with SwiftUI (no Swift Charts) so every date label is
//  guaranteed to align with its bar, and hovering a bar shows its value.
//

import SwiftUI

/// Normalized horizontal position for a value on the bar chart's X axis.
/// Values outside the visible domain are clamped so log-scale end ticks stay
/// on the plot instead of extending past its right edge.
func trafficBarXAxisPosition(for value: Double, maxValue: Double) -> CGFloat {
    guard maxValue.isFinite, maxValue > 0 else { return 0 }
    return trafficBarXAxisPosition(for: value, domain: 0...maxValue)
}

/// Returns a rounded log10 domain that contains all plotted values.
///
/// A log axis must not be normalized against an implicit zero origin: doing
/// that puts every positive value close to the right edge. Rounding the
/// domain to powers of ten keeps the axis readable while preserving the
/// values' absolute order of magnitude.
func trafficBarLogDomain(for values: [Double]) -> ClosedRange<Double> {
    let finiteValues = values.filter { $0.isFinite }
    guard let minimum = finiteValues.min(), let maximum = finiteValues.max() else {
        return 0...1
    }

    let lowerBound = max(0, floor(minimum))
    let upperBound = max(ceil(maximum), lowerBound + 1)
    return lowerBound...upperBound
}

/// Normalized horizontal position for a value within an explicit axis domain.
func trafficBarXAxisPosition(for value: Double, domain: ClosedRange<Double>) -> CGFloat {
    let lowerBound = domain.lowerBound
    let upperBound = domain.upperBound
    let span = upperBound - lowerBound
    guard value.isFinite,
          lowerBound.isFinite,
          upperBound.isFinite,
          span > 0 else {
        return 0
    }

    return CGFloat(min(max((value - lowerBound) / span, 0), 1))
}

enum TrafficBarXAxisBehavior: Equatable {
    case topPinned
}

func trafficBarXAxisBehavior() -> TrafficBarXAxisBehavior {
    .topPinned
}

func trafficBarPointsNewestFirst(_ points: [BarPeriodPoint]) -> [BarPeriodPoint] {
    points.sorted { $0.period > $1.period }
}

func tooltipPosition(for pointer: CGPoint, in size: CGSize) -> CGPoint {
    let horizontalGap: CGFloat = 16
    let verticalGap: CGFloat = 10
    let halfTooltipHeight: CGFloat = 15

    let x = min(max(pointer.x + horizontalGap, 70), max(70, size.width - 70))
    let above = pointer.y - halfTooltipHeight - verticalGap
    let y = above >= halfTooltipHeight
        ? above
        : pointer.y + halfTooltipHeight + verticalGap
    return CGPoint(x: x, y: y)
}

struct BarHoverSelection: Equatable {
    private(set) var activeBarID: String?

    mutating func update(activeBarID: String?) {
        self.activeBarID = activeBarID
    }
}

struct TrafficBarChartView: View {
    let points: [BarPeriodPoint]
    let scaleMode: BarScaleMode
    let emptyText: String

    /// Height reserved per bar row (bar + its label).
    private let barPitch: CGFloat = 26
    /// Width of the left-hand date-label column.
    private let labelWidth: CGFloat = 78
    /// Gap between the label column and the plot area.
    private let labelToPlotSpacing: CGFloat = 8
    /// Number of X-axis ticks (grid lines + labels).
    private let tickCount = 5

    @State private var hoverSelection = BarHoverSelection()
    @State private var hoveredLocation: CGPoint = .zero

    /// Total left inset shared by bar rows and the X axis so the plot area
    /// starts at exactly the same x on every row.
    private var leftInset: CGFloat { labelWidth + labelToPlotSpacing }

    /// Internal bar values: x is already log10-transformed in log mode.
    private struct BarValue: Identifiable {
        let id: String
        let label: String
        let x: Double
        let bytes: Int
    }

    private var barValues: [BarValue] {
        trafficBarPointsNewestFirst(points).map { point in
            let x: Double
            switch scaleMode {
            case .linear:
                x = Double(max(point.totalBytes, 0))
            case .log:
                // Never log10(0): floors at 1 byte so the value stays finite.
                x = log10(Double(max(point.totalBytes, 1)))
            }
            return BarValue(id: point.label, label: point.label, x: x, bytes: point.totalBytes)
        }
    }

    /// Visible X-axis domain in data (x) space.
    private var xDomain: ClosedRange<Double> {
        switch scaleMode {
        case .linear:
            return 0...max(barValues.map(\.x).max() ?? 1, 1e-9)
        case .log:
            return trafficBarLogDomain(for: barValues.map(\.x))
        }
    }

    /// X-axis tick positions in data (x) space.
    private var ticks: [Double] {
        switch scaleMode {
        case .linear:
            let step = (xDomain.upperBound - xDomain.lowerBound) / Double(tickCount - 1)
            return (0..<tickCount).map { xDomain.lowerBound + Double($0) * step }
        case .log:
            let lowerExponent = Int(xDomain.lowerBound.rounded())
            let upperExponent = Int(xDomain.upperBound.rounded())
            return (lowerExponent...upperExponent).map(Double.init)
        }
    }

    private func tickLabel(_ value: Double) -> String {
        switch scaleMode {
        case .linear:
            return formatBytesTotal(bytes: Int(value))
        case .log:
            return formatBytesTotal(bytes: Int(pow(10, value)))
        }
    }

    var body: some View {
        if points.isEmpty {
            emptyState
        } else {
            chart
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            let plotWidth = max(1, geo.size.width - leftInset)
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    let xAxisBehavior = trafficBarXAxisBehavior()
                    LazyVStack(
                        spacing: 0,
                        pinnedViews: xAxisBehavior == .topPinned ? [.sectionHeaders] : []
                    ) {
                        Section {
                            ForEach(barValues) { bar in
                                barRow(bar, plotWidth: plotWidth)
                                    .contentShape(Rectangle())
                                    .onContinuousHover(coordinateSpace: .named("bars")) { phase in
                                        switch phase {
                                        case .active(let location):
                                            hoverSelection.update(activeBarID: bar.id)
                                            hoveredLocation = location
                                        case .ended:
                                            if hoverSelection.activeBarID == bar.id {
                                                hoverSelection.update(activeBarID: nil)
                                            }
                                        }
                                    }
                            }
                        } header: {
                            xAxis(plotWidth: plotWidth)
                                .background(Color(nsColor: .windowBackgroundColor))
                                .zIndex(1)
                        }
                    }

                    if let hoveredBar = barValues.first(where: { $0.id == hoverSelection.activeBarID }) {
                        tooltip(bar: hoveredBar)
                            .position(tooltipPosition(for: hoveredLocation, in: geo.size))
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "bars")
            }
        }
    }

    /// One row: date label on the left, bar on the right. Both share the same
    /// row height (`barPitch`) and the plot area starts at the same left inset
    /// as the X axis, so label, bar and ticks all line up.
    private func barRow(_ bar: BarValue, plotWidth: CGFloat) -> some View {
        let ratio = trafficBarXAxisPosition(for: bar.x, domain: xDomain)
        return HStack(spacing: labelToPlotSpacing) {
            Text(bar.label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, height: barPitch, alignment: .trailing)

            ZStack(alignment: .leading) {
                // Track (subtle background) to make short bars visible.
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.cardStroke.opacity(0.5))
                    .frame(width: plotWidth, height: 14)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.download)
                    .frame(width: max(2, plotWidth * ratio), height: 14)
            }
        }
        .frame(width: plotWidth + leftInset, height: barPitch, alignment: .leading)
    }

    /// X-axis tick labels and grid lines aligned to the plot area.
    private func xAxis(plotWidth: CGFloat) -> some View {
        HStack(spacing: labelToPlotSpacing) {
            Color.clear
                .frame(width: labelWidth, height: 0)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.cardStroke)
                    .frame(width: plotWidth, height: 1)

                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    let pos = trafficBarXAxisPosition(for: tick, domain: xDomain)
                    Rectangle()
                        .fill(Theme.cardStroke)
                        .frame(width: 1, height: 5)
                        .position(x: plotWidth * pos, y: 2.5)

                    Text(tickLabel(tick))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize()
                        .position(x: plotWidth * pos, y: 13)
                }
            }
            .frame(width: plotWidth, height: 26, alignment: .topLeading)
        }
        .frame(width: plotWidth + leftInset, alignment: .leading)
    }

    private func tooltip(bar: BarValue) -> some View {
        let value = formatBytesTotal(bytes: bar.bytes)
        return Text("\(bar.label) · \(value)")
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardStroke))
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(emptyText)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
