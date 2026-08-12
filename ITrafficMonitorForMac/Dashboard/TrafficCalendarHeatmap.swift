//
//  TrafficCalendarHeatmap.swift
//  ITrafficMonitorForMac
//
//  GitHub-style calendar heatmap for 30 Days / This Month ranges.
//  Columns are weeks, rows are Mon–Sun (respecting `calendar.firstWeekday`),
//  each cell is one day colored by its total traffic.
//

import SwiftUI

struct TrafficCalendarHeatmap: View {
    let cells: [CalendarDayCell]
    let maxBytes: Int
    let emptyText: String
    let calendar: Calendar

    /// Gap between adjacent cells in the grid.
    private let spacing: CGFloat = 3
    /// Height of the month-label row above the grid.
    private let monthLabelHeight: CGFloat = 16
    /// Width reserved for the Mon–Sun column on the left.
    private let weekdayLabelWidth: CGFloat = 26

    @State private var hovered: (cell: CalendarDayCell, location: CGPoint)?
    @State private var gridSize: CGSize = .zero

    // MARK: - Grid geometry

    private var startDay: Int { cells.first?.day ?? 0 }
    private var lastDay: Int { cells.last?.day ?? 0 }
    private var totalDays: Int { max(0, lastDay - startDay + 1) }

    private var totalsByDay: [Int: Int] {
        Dictionary(uniqueKeysWithValues: cells.map { ($0.day, $0.totalBytes) })
    }

    /// Row 0...6 for a day, normalized so `calendar.firstWeekday` is row 0.
    private func rowIndex(for day: Int) -> Int {
        let date = dateFromDay(day)
        let weekday = calendar.component(.weekday, from: date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// The row the first day of the range lands on.
    private var firstRow: Int {
        guard totalDays > 0 else { return 0 }
        return rowIndex(for: startDay)
    }

    /// Number of week columns needed to cover `[startDay, lastDay]`.
    private var numWeeks: Int {
        guard totalDays > 0 else { return 1 }
        return Int(ceil(Double(firstRow + totalDays) / 7.0))
    }

    /// Absolute `day` value at a grid position, or one outside the range
    /// when the position maps to a blank cell.
    private func day(at week: Int, row: Int) -> Int {
        startDay - firstRow + week * 7 + row
    }

    private func isValidDay(_ day: Int) -> Bool {
        day >= startDay && day <= lastDay
    }

    /// First in-range day of a week column, used for month labels.
    private func firstValidDay(inWeek week: Int) -> Int? {
        for row in 0..<7 {
            let d = day(at: week, row: row)
            if isValidDay(d) { return d }
        }
        return nil
    }

    /// Which week columns start a new month (GitHub-style month labels).
    private var monthStartWeeks: Set<Int> {
        var result: Set<Int> = []
        var prevMonth = Int.min
        for week in 0..<numWeeks {
            guard let day = firstValidDay(inWeek: week) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: dateFromDay(day))
            let month = (comps.year ?? 0) * 12 + (comps.month ?? 0)
            if month != prevMonth {
                result.insert(week)
                prevMonth = month
            }
        }
        return result
    }

    /// Square cell size that fits the available area.
    private func cellSize(for size: CGSize) -> CGFloat {
        let usableWidth = max(1, size.width - weekdayLabelWidth)
        let colPitch = usableWidth / CGFloat(numWeeks)
        let rowPitch = size.height / 7
        return max(6, min(colPitch, rowPitch) - spacing)
    }

    private var locale: Locale { calendar.locale ?? .current }

    // MARK: - Body

    var body: some View {
        if cells.isEmpty {
            emptyState
        } else {
            GeometryReader { geo in
                content(geo)
            }
        }
    }

    private func content(_ geo: GeometryProxy) -> some View {
        let cell = cellSize(for: geo.size)
        let colPitch = cell + spacing
        let rowPitch = cell + spacing
        let gridWidth = CGFloat(numWeeks) * colPitch - spacing
        let gridHeight = 7 * rowPitch - spacing

        return HStack(alignment: .top, spacing: 8) {
            weekdayColumn(cell: cell, rowPitch: rowPitch)
            VStack(alignment: .leading, spacing: 0) {
                monthRow(cell: cell, gridWidth: gridWidth)
                grid(cell: cell, gridWidth: gridWidth, gridHeight: gridHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func weekdayColumn(cell: CGFloat, rowPitch: CGFloat) -> some View {
        VStack(spacing: spacing) {
            Color.clear.frame(height: monthLabelHeight)
            ForEach(0..<7, id: \.self) { row in
                Text(weekdaySymbol(row))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: weekdayLabelWidth, height: cell, alignment: .trailing)
            }
        }
        .frame(width: weekdayLabelWidth)
    }

    private func weekdaySymbol(_ row: Int) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        guard !symbols.isEmpty else { return "" }
        return symbols[(row + calendar.firstWeekday - 1) % symbols.count]
    }

    private func monthRow(cell: CGFloat, gridWidth: CGFloat) -> some View {
        // Each month label is anchored to the column where that month's first
        // day falls, but the label itself keeps its natural (unclamped) width.
        // Clamping it to the ~13px cell width would truncate "Sep" → "…".
        ZStack(alignment: .topLeading) {
            ForEach(0..<numWeeks, id: \.self) { week in
                if monthStartWeeks.contains(week), let day = firstValidDay(inWeek: week) {
                    Text(dateFromDay(day).formatted(.dateTime.month(.abbreviated).locale(locale)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: CGFloat(week) * (cell + spacing))
                }
            }
        }
        .frame(width: gridWidth, height: monthLabelHeight, alignment: .topLeading)
        .clipped()
    }

    private func grid(cell: CGFloat, gridWidth: CGFloat, gridHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: spacing) {
                ForEach(0..<numWeeks, id: \.self) { week in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            cellView(week: week, row: row)
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)

            if let hovered {
                let location = clampedLocation(hovered.location, size: gridSize)
                tooltip(cell: hovered.cell)
                    .position(x: location.x, y: location.y)
            }
        }
        .frame(width: gridWidth, height: gridHeight)
        .background(GeometryReader { proxy in
            Color.clear.onAppear {
                gridSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                gridSize = newSize
            }
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let week = Int(location.x / (cell + spacing))
                let row = Int(location.y / (cell + spacing))
                guard week >= 0, week < numWeeks, row >= 0, row < 7 else {
                    hovered = nil
                    return
                }
                let d = day(at: week, row: row)
                guard isValidDay(d), let bytes = totalsByDay[d] else {
                    hovered = nil
                    return
                }
                hovered = (cell: CalendarDayCell(day: d, totalBytes: bytes), location: location)
            case .ended:
                hovered = nil
            }
        }
    }

    @ViewBuilder
    private func cellView(week: Int, row: Int) -> some View {
        let d = day(at: week, row: row)
        if isValidDay(d) {
            RoundedRectangle(cornerRadius: 3)
                .fill(cellColor(totalsByDay[d] ?? 0))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.clear)
        }
    }

    private func cellColor(_ bytes: Int) -> Color {
        let ratio = Double(bytes) / Double(max(maxBytes, 1))
        return Theme.heatmap.opacity(0.22 + 0.78 * ratio)
    }

    private func clampedLocation(_ location: CGPoint, size: CGSize) -> CGPoint {
        let w = size.width
        let h = size.height
        // Keep the tooltip fully inside the grid with a small margin.
        let x = min(max(location.x, 40), max(40, w - 40))
        let y = min(max(location.y, 14), max(14, h - 14))
        return CGPoint(x: x, y: y)
    }

    private func tooltip(cell: CalendarDayCell) -> some View {
        let date = dateFromDay(cell.day).formatted(.dateTime.month().day().locale(locale))
        let value = formatBytesTotal(bytes: cell.totalBytes)
        return Text("\(date) · \(value)")
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
