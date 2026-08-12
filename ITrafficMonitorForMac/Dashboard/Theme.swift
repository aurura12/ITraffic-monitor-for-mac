//
//  Theme.swift
//  ITrafficMonitorForMac
//
//  Shared design tokens for the unified dashboard.
//

import SwiftUI

enum Theme {
    /// Card surface used for stat cards and chart containers.
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.85)

    /// Subtle border for elevated cards.
    static let cardStroke = Color.white.opacity(0.06)

    /// Download accent (used for values and chart lines).
    static let download = Color(red: 0.25, green: 0.55, blue: 1.0)

    /// Upload accent.
    static let upload = Color(red: 1.0, green: 0.58, blue: 0.0)

    /// Neutral total accent.
    static let total = Color(red: 0.9, green: 0.9, blue: 0.9)

    /// Heatmap cell color (blue-purple; intensity is controlled via opacity).
    static let heatmap = Color(red: 0.45, green: 0.52, blue: 0.95)

    /// Primary text on cards (adapts to light/dark).
    static let textPrimary = Color.primary

    /// Secondary/muted text.
    static let textSecondary = Color.secondary

    /// Standard corner radius for dashboard cards.
    static let cornerRadius: CGFloat = 12

    /// Standard padding inside dashboard cards.
    static let cardPadding: CGFloat = 16
}
