// PopoverComponents.swift
// DataHawk
//
// Reusable SwiftUI building blocks used across the popover and potentially
// other views. Kept in a dedicated file to avoid bloating the section views.

import SwiftUI

// MARK: - Data usage progress bar

/// Animated horizontal bar that fills proportionally to data consumption.
/// Colour transitions green -> orange -> red as usage increases.
struct DataUsageBar: View {
    /// Fraction of the data cap consumed (0.0 - 1.0).
    let percent: Double

    private var barColor: Color {
        if percent < 0.70 { return .green }
        if percent < 0.90 { return .orange }
        return .red
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track (background).
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 6)

                // Fill (foreground).
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: geo.size.width * CGFloat(percent), height: 6)
                    .animation(.easeOut(duration: 0.4), value: percent)
            }
        }
        .frame(height: 6)
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
