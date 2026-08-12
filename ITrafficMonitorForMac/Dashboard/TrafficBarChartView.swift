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

    @State private var hovered: (bar: BarValue, location: CGPoint)?

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
        points.map { point in
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

    /// X-axis tick positions in data (x) space.
    private var ticks: [Double] {
        guard let maxX = barValues.map(\.x).max(), maxX > 0 else { return [] }
        switch scaleMode {
        case .linear:
            let step = maxX / Double(tickCount - 1)
            return (0..<tickCount).map { Double($0) * step }
        case .log:
            let loExp = max(0, Int(floor(barValues.map(\.x).min() ?? 0)))
            let hiExp = Int(ceil(maxX))
            return (loExp...hiExp).map { Double($0) }
        }
    }

    /// Max value used to scale bar widths.
    private var maxX: Double {
        max(barValues.map(\.x).max() ?? 1, 1e-9)
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
                    VStack(spacing: 0) {
                        ForEach(barValues) { bar in
                            barRow(bar, plotWidth: plotWidth)
                        }
                        xAxis(plotWidth: plotWidth)
                    }

                    if let hovered {
                        tooltip(bar: hovered.bar)
                            .position(x: hovered.location.x, y: hovered.location.y)
                    }
                }
                .coordinateSpace(name: "bars")
                .background(
                    GeometryReader { contentGeo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover(coordinateSpace: .named("bars")) { phase in
                                switch phase {
                                case .active(let location):
                                    let row = Int(location.y / barPitch)
                                    if row >= 0, row < barValues.count {
                                        hovered = (bar: barValues[row], location: location)
                                    } else {
                                        hovered = nil
                                    }
                                case .ended:
                                    hovered = nil
                                }
                            }
                    }
                )
            }
        }
    }

    /// One row: date label on the left, bar on the right. Both share the same
    /// row height (`barPitch`) and the plot area starts at the same left inset
    /// as the X axis, so label, bar and ticks all line up.
    private func barRow(_ bar: BarValue, plotWidth: CGFloat) -> some View {
        let ratio = bar.x / maxX
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
            VStack(spacing: 2) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        let pos = tick / maxX
                        Rectangle()
                            .fill(Theme.cardStroke)
                            .frame(width: 1, height: 4)
                            .offset(x: plotWidth * pos)
                    }
                }
                .frame(width: plotWidth, height: 4, alignment: .leading)

                ZStack(alignment: .topLeading) {
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        let pos = tick / maxX
                        Text(tickLabel(tick))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .fixedSize()
                            .position(x: plotWidth * pos - plotWidth / 2, y: 7)
                    }
                }
                .frame(width: plotWidth, height: 14, alignment: .leading)
            }
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
