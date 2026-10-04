//
//  Theme.swift
//  ITrafficMonitorForMac
//
//  Shared design tokens for the unified dashboard.
//

import AppKit
import SwiftUI

enum Theme {
    /// Native window surface follows the app's effective appearance.
    static let windowBackground = Color(nsColor: .windowBackgroundColor)

    /// Card surface used for stat cards and chart containers.
    static let cardBackground = adaptiveColor(
        light: .white,
        dark: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
    )

    /// Subtle border for elevated cards.
    static let cardStroke = adaptiveColor(
        light: .black.withAlphaComponent(0.10),
        dark: .white.withAlphaComponent(0.14)
    )

    /// Chart guides and bar tracks need their own contrast on both surfaces.
    static let gridLine = adaptiveColor(
        light: .black.withAlphaComponent(0.12),
        dark: .white.withAlphaComponent(0.18)
    )
    static let barTrack = adaptiveColor(
        light: .black.withAlphaComponent(0.04),
        dark: .white.withAlphaComponent(0.06)
    )
    static let heatmapEmpty = adaptiveColor(
        light: .black.withAlphaComponent(0.06),
        dark: .white.withAlphaComponent(0.10)
    )

    /// Opaque tooltips keep chart marks from showing through their text.
    static let tooltipBackground = adaptiveColor(
        light: .white,
        dark: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1)
    )
    static let tooltipShadow = adaptiveColor(
        light: .black.withAlphaComponent(0.12),
        dark: .black.withAlphaComponent(0.35)
    )

    /// Download accent (used for values and chart lines).
    static let download = adaptiveColor(
        light: NSColor(srgbRed: 0.12, green: 0.42, blue: 0.83, alpha: 1),
        dark: NSColor(srgbRed: 0.38, green: 0.66, blue: 1.0, alpha: 1)
    )

    /// Upload accent.
    static let upload = adaptiveColor(
        light: NSColor(srgbRed: 0.69, green: 0.34, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.68, blue: 0.30, alpha: 1)
    )

    /// Blue-purple total accent, kept distinct from download and upload.
    static let total = adaptiveColor(
        light: NSColor(srgbRed: 0.38, green: 0.40, blue: 0.82, alpha: 1),
        dark: NSColor(srgbRed: 0.64, green: 0.66, blue: 1.0, alpha: 1)
    )

    /// Heatmap cell color (blue-purple; intensity is controlled via opacity).
    static let heatmap = adaptiveColor(
        light: NSColor(srgbRed: 0.45, green: 0.52, blue: 0.95, alpha: 1),
        dark: NSColor(srgbRed: 0.55, green: 0.60, blue: 1.0, alpha: 1)
    )

    /// Keep colors dynamic so existing windows update when appearance changes.
    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Standard corner radius for dashboard cards.
    static let cornerRadius: CGFloat = 12

    /// Standard padding inside dashboard cards.
    static let cardPadding: CGFloat = 16
}
