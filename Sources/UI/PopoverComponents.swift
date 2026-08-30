// PopoverComponents.swift
// DataHawk
//
// Reusable SwiftUI building blocks used across the popover and potentially
// other views. Kept in a dedicated file to avoid bloating the section views.

import SwiftUI

// MARK: - Data usage progress bar

/// Animated horizontal bar that fills proportionally to `percent`.
/// The caller owns the fill colour so the bar can carry the same semantic
/// tint as the metric it illustrates.
struct DataUsageBar: View {
    /// Fraction of the bar that is filled (0.0 - 1.0).
    let percent: Double

    /// Fill colour.
    let color: Color

    private static let height: CGFloat = 6

    /// Clamped fill fraction, safe to multiply a width by.
    private var fraction: CGFloat { CGFloat(min(max(percent, 0), 1)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track (background).
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))

                // Fill (foreground).
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * fraction)
                    .animation(.easeOut(duration: 0.4), value: percent)
            }
        }
        .frame(height: Self.height)
    }
}

// MARK: - Signal bars indicator

/// Five-bar cellular signal indicator similar to the iOS / macOS system icon.
/// Bars from 1 (shortest) to 5 (tallest) light up according to `strength`.
struct SignalBarsView: View {
    /// Signal strength in the range 0-5.
    let strength: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...5, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(bar <= strength ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(4 + bar * 3))
            }
        }
    }
}
