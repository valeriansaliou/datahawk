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
//   - Connected (offloading): wave icon (template) — not on cellular
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
    ///   - offloading:         When `true` a wave icon replaces the network badge —
    ///                         the cellular generation is irrelevant while the
    ///                         router routes over Ethernet or upstream WiFi.
    static func icon(
        state: ConnectionState,
        networkType: NetworkType?,
        batteryLow: Bool = false,
        highDataUsage: Bool = false,
        routerNotConnected: Bool = false,
        simLocked: Bool = false,
        offloading: Bool = false
    ) -> NSImage {
        switch state {
        case .noHotspot:
            // Slashed antenna at full opacity — not on any known hotspot network.
            return sfSymbol("antenna.radiowaves.left.and.right.slash")

        case .disconnected, .failed:
            // Faded normal antenna — hotspot known but no data yet.
            return faded(tintedSFIcon("antenna.radiowaves.left.and.right", color: .white))

        case .loading:
            return sfSymbol("antenna.radiowaves.left.and.right")

        case .connected:
            if simLocked  { return tintedSFIcon("simcard", color: .orange) }
            if offloading { return sfSymbol("wave.3.right") }

            let type = networkType ?? .unknown

            switch type {
            case .noSignal:
                return faded(tintedSFIcon("cellularbars", color: .white))
            case .unknown:
                return sfSymbol("cellularbars")
            default:
                if routerNotConnected { return faded(textIcon(type.rawValue, color: .white)) }
                if highDataUsage      { return textIcon(type.rawValue, backgroundColor: .orange) }
                if batteryLow         { return textIcon(type.rawValue, backgroundColor: .systemRed) }
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

        return faded(base, fraction: clamped)
    }

    // MARK: - Helpers (private)

    /// Composites `base` at the given opacity into a fresh non-template image.
    /// Used for greyed-out states (disconnected, failed, no signal) and for
    /// the loading blink animation.
    private static func faded(_ base: NSImage, fraction: CGFloat = 0.35) -> NSImage {
        let result = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
            return true
        }

        result.isTemplate = false
        return result
    }

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
    ///
    /// - `color`:           Tints the text; `nil` produces a template image.
    /// - `backgroundColor`: When set, draws a rounded filled box in that colour
    ///                      with white text — used for alert states (battery low,
    ///                      high data usage) instead of coloured text.
    private static func textIcon(
        _ label: String,
        color: NSColor? = nil,
        backgroundColor: NSColor? = nil
    ) -> NSImage {
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]

        let nsLabel  = label as NSString
        let textSize = nsLabel.size(withAttributes: sizeAttrs)

        let hPad: CGFloat = backgroundColor != nil ? 6 : 1
        let vPad: CGFloat = backgroundColor != nil ? 2 : 0

        let imgSize = NSSize(
            width:  ceil(textSize.width)  + hPad * 2,
            height: ceil(textSize.height) + vPad * 2
        )

        let image = NSImage(size: imgSize, flipped: false) { _ in
            if let bg = backgroundColor {
                // Resolve text colour inside the drawing closure so
                // NSAppearance.current reflects the actual rendering context.
                let drawAttrs: [NSAttributedString.Key: Any] = [
                    .font:            NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]

                let path = NSBezierPath(
                    roundedRect: NSRect(origin: .zero, size: imgSize),
                    xRadius: 6, yRadius: 6
                )
                bg.setFill()
                path.fill()

                nsLabel.draw(
                    in: NSRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height),
                    withAttributes: drawAttrs
                )
            } else {
                let drawAttrs: [NSAttributedString.Key: Any] = [
                    .font:            NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: color ?? NSColor.black,
                ]

                nsLabel.draw(
                    in: NSRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height),
                    withAttributes: drawAttrs
                )
            }
            return true
        }

        image.isTemplate = color == nil && backgroundColor == nil
        return image
    }
}
