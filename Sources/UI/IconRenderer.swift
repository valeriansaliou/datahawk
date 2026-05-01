// IconRenderer.swift
// DataHawk
//
// Generates the NSImage shown in the macOS status bar. All images are
// template images (unless tinted) so they adapt automatically to light/dark
// mode and the highlighted (blue) menu-bar state.
//
// Icon states:
//   - No hotspot            : slashed antenna at full opacity (template)
//   - Disconnected          : faded normal antenna at 35 % opacity
//   - Failed                : faded normal antenna at 35 % opacity
//   - Loading               : antenna blinking (caller varies alpha via opacity)
//   - Connected (no signal) : faded cellular-bars at 35 % opacity
//   - Connected (signal)    : text badge ("5G", "4G", ...) coloured by alerts

import AppKit

enum IconRenderer {

    // MARK: - Public API

    /// Returns the status-bar icon for the given state.
    ///
    /// - Parameters:
    ///   - state:              Current connection state.
    ///   - networkType:        Cellular generation (used for the text badge).
    ///   - batteryLow:         When `true` the badge is rendered in red.
    ///   - highDataUsage:      When `true` the badge is rendered in orange.
    ///   - routerNotConnected: When `true` the text badge is rendered at 35 % opacity.
    ///   - simLocked:          When `true` an orange SIM card icon is shown.
    static func icon(
        state: ConnectionState,
        networkType: NetworkType?,
        batteryLow: Bool = false,
        highDataUsage: Bool = false,
        routerNotConnected: Bool = false,
        simLocked: Bool = false
    ) -> NSImage {
        switch state {
        case .noHotspot:
            // Slashed antenna at full opacity — not on any known hotspot network.
            return sfSymbol("antenna.radiowaves.left.and.right.slash")

        case .disconnected, .failed:
            // Faded normal antenna at 35 % opacity — hotspot known but no data yet.
            let base   = tintedSFIcon("antenna.radiowaves.left.and.right", color: .white)
            let result = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)
                return true
            }
            result.isTemplate = false
            return result

        case .loading:
            return sfSymbol("antenna.radiowaves.left.and.right")

        case .connected:
            if simLocked { return tintedSFIcon("simcard", color: .orange) }

            let type = networkType ?? .unknown

            switch type {
            case .noSignal:
                let base   = tintedSFIcon("cellularbars", color: .white)
                let result = NSImage(size: base.size, flipped: false) { rect in
                    base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)
                    return true
                }
                result.isTemplate = false
                return result
            case .unknown:
                return sfSymbol("cellularbars")
            default:
                if routerNotConnected {
                    let base   = textIcon(type.rawValue, color: .white)
                    let result = NSImage(size: base.size, flipped: false) { rect in
                        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)
                        return true
                    }
                    result.isTemplate = false
                    return result
                }
                if highDataUsage { return textIcon(type.rawValue, color: .orange) }
                if batteryLow    { return textIcon(type.rawValue, color: .systemRed) }
                return textIcon(type.rawValue)
            }
        }
    }

    /// Returns the loading-state icon at a specific opacity (0.0-1.0) for
    /// smooth blink animation. Draws a fully-opaque white icon composited at
    /// `fraction` to avoid palette-colour quirks.
    static func loadingIcon(alpha: CGFloat = 1.0) -> NSImage {
        let clamped = max(0.0, min(1.0, alpha))
        let base    = tintedSFIcon("antenna.radiowaves.left.and.right", color: .white)

        // No compositing needed at full opacity.
        if clamped >= 0.99 { return base }

        let result = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: clamped)
            return true
        }

        result.isTemplate = false
        return result
    }

    // MARK: - Helpers (private)

    /// Renders an SF Symbol as a small template image sized for the menu bar.
    private static func sfSymbol(_ name: String) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()

        img.isTemplate = true
        return img
    }

    /// Renders an SF Symbol as a non-template image in an explicit colour.
    private static func tintedSFIcon(_ name: String, color: NSColor) -> NSImage {
        let sizeCfg  = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let colorCfg = NSImage.SymbolConfiguration(paletteColors: [color])
        let cfg      = sizeCfg.applying(colorCfg)
        let img      = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()

        img.isTemplate = false
        return img
    }

    /// Renders a short text label (e.g. "5G", "4G") as a menu-bar image.
    /// Pass a colour for a non-template tinted icon; `nil` gives a template
    /// image that adapts to light/dark mode automatically.
    private static func textIcon(_ label: String, color: NSColor? = nil) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color ?? .black,
        ]

        let nsLabel  = label as NSString
        let textSize = nsLabel.size(withAttributes: attrs)
        let imgSize  = NSSize(
            width: ceil(textSize.width) + 2,
            height: ceil(textSize.height)
        )

        let image = NSImage(size: imgSize, flipped: false) { _ in
            nsLabel.draw(
                in: NSRect(x: 1, y: 0, width: textSize.width, height: textSize.height),
                withAttributes: attrs
            )
            return true
        }

        image.isTemplate = color == nil
        return image
    }
}
