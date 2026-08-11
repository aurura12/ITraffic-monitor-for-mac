//
//  ExportView.swift
//  ITrafficMonitorForMac
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable {
    case csv = "CSV"
    case json = "JSON"
}

enum ExportRange: Int, CaseIterable {
    case oneDay = 1
    case week = 7
    case month30 = 30
    case month90 = 90

    var label: String {
        switch self {
        case .oneDay: return "1 Day"
        case .week: return "7 Days"
        case .month30: return "30 Days"
        case .month90: return "90 Days"
        }
    }
}

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var i18n: LocalizationManager

    @State private var format: ExportFormat = .csv
    @State private var granularity: ExportGranularity = .day
    @State private var range: ExportRange = .month30
    @State private var isExporting = false
    @State private var errorMessage: String?

    private let recorder = SharedStore.recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(i18n.text("Export Traffic Data"))
                .font(.headline)

            Picker(i18n.text("Format"), selection: $format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }

            Picker(i18n.text("Granularity"), selection: $granularity) {
                ForEach(ExportGranularity.allCases, id: \.self) { Text(i18n.text($0.label)).tag($0) }
            }
            .onChange(of: granularity) { g in
                if g == .minute { range = .oneDay }
            }

            Picker(i18n.text("Range"), selection: $range) {
                ForEach(ExportRange.allCases, id: \.self) { Text(i18n.text($0.label)).tag($0) }
            }
            .disabled(granularity == .minute)

            if granularity == .minute {
                Text(i18n.text("Minute granularity is limited to 1 day to keep the file size reasonable."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button(i18n.text("Cancel")) { dismiss() }
                Button(isExporting ? i18n.text("Exporting…") : i18n.text("Export")) { export() }
                    .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 380)
        .alert(i18n.text("Export Failed"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(i18n.text("OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func export() {
        isExporting = true
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: todayStart)!

        recorder.exportRows(
            start: Int(start.timeIntervalSince1970),
            end: Int(tomorrow.timeIntervalSince1970),
            granularity: granularity
        ) { [self] rows in
            finishExport(rows: rows)
        }
    }

    private func finishExport(rows: [ExportTrafficRow]) {
        let data: Data
        do {
            switch format {
            case .csv:
                data = try Self.csvData(rows: rows)
            case .json:
                data = try Self.jsonData(rows: rows)
            }
        } catch {
            isExporting = false
            errorMessage = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "traffic-\(granularity.label.lowercased())-\(range.label).\(format == .csv ? "csv" : "json")"
        panel.begin { [self] response in
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            isExporting = false
        }
    }

    // MARK: - Serialization

    private static func csvData(rows: [ExportTrafficRow]) throws -> Data {
        var csv = "period,app,display_name,in_bytes,out_bytes\n"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for r in rows {
            csv += "\(csvField(fmt.string(from: r.period))),"
                + "\(csvField(r.appKey)),"
                + "\(csvField(r.displayName)),"
                + "\(r.inBytes),\(r.outBytes)\n"
        }
        return Data(csv.utf8)
    }

    private static func jsonData(rows: [ExportTrafficRow]) throws -> Data {
        struct Record: Encodable {
            let period: Date
            let app: String
            let displayName: String
            let inBytes: Int
            let outBytes: Int
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows.map {
            Record(period: $0.period, app: $0.appKey, displayName: $0.displayName,
                   inBytes: $0.inBytes, outBytes: $0.outBytes)
        })
    }

    /// RFC 4180-style quoting for fields containing commas, quotes or newlines.
    /// Also neutralises spreadsheet formula injection by prefixing cells that
    /// start with `= + - @` with a single quote (OWASP mitigation).
    private static func csvField(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+-@".contains(first) {
            v = "'" + v
        }
        return v.contains(",") || v.contains("\"") || v.contains("\n")
            ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : v
    }
}
