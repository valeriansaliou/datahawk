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
//
// A faded "heat.waves" glyph is appended to the right of the connected icon
// whenever the router reports a critical device temperature or an abnormal
// battery temperature.

import AppKit

enum IconRenderer {

    // MARK: - Public API

    /// Returns the status-bar icon for the given state.
    ///
    /// - Parameters:
    ///   - state:              Current connection state.
    ///   - networkType:        Cellular generation (used for the text badge).
    ///   - batteryLow:         When `true` the badge is rendered in red.
    ///   - highDataUsage:      When `true` a faded dollarsign glyph is appended to
    ///                         the right of the connected icon.
    ///   - routerNotConnected: When `true` the text badge is rendered at 35 % opacity.
    ///   - simLocked:          When `true` an orange "SIM" badge is shown.
    ///   - offloading:         When `true` a wave icon replaces the network badge —
    ///                         the cellular generation is irrelevant while the
    ///                         router routes over Ethernet or upstream WiFi.
    ///   - overheating:        When `true` a faded heat glyph is appended to the
    ///                         right of the connected icon.
    static func icon(
        state: ConnectionState,
        networkType: NetworkType?,
        batteryLow: Bool = false,
        highDataUsage: Bool = false,
        routerNotConnected: Bool = false,
        simLocked: Bool = false,
        offloading: Bool = false,
        overheating: Bool = false
    ) -> NSImage {
        let base = baseIcon(
            state: state,
            networkType: networkType,
            batteryLow: batteryLow,
            routerNotConnected: routerNotConnected,
            simLocked: simLocked,
            offloading: offloading
        )

        guard case .connected = state else { return base }

        var icon = base
        if highDataUsage {
            icon = appendingGlyph("dollarsign", to: icon)
        }
        if overheating {
            icon = appendingGlyph("heat.waves", to: icon)
        }

        return icon
    }

    private static func baseIcon(
        state: ConnectionState,
        networkType: NetworkType?,
        batteryLow: Bool,
        routerNotConnected: Bool,
        simLocked: Bool,
        offloading: Bool
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
            if simLocked  { return textIcon("SIM", backgroundColor: .orange, badgeSymbol: "simcard") }
            if offloading { return sfSymbol("wave.3.right") }

            let type = networkType ?? .unknown

            switch type {
            case .noSignal:
                return faded(tintedSFIcon("cellularbars", color: .white))
            case .unknown:
                return sfSymbol("cellularbars")
            default:
                if routerNotConnected { return faded(textIcon(type.rawValue, color: .white)) }
                if batteryLow         { return textIcon(type.rawValue, backgroundColor: .systemRed, badgeSymbol: "battery.0percent") }
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

    /// Appends a faded SF Symbol to the right of `base`, preserving its
    /// template-ness so the pair still adapts to the menu-bar appearance.
    /// The glyph is drawn in the icon's main colour at reduced opacity, which
    /// reads as grey next to the full-opacity badge.
    private static func appendingGlyph(
        _ symbol: String,
        to base: NSImage,
        fraction: CGFloat = 0.45
    ) -> NSImage {
        // Template images are tinted by AppKit from their mask, so black is
        // the "main colour" there; faded/badged icons are already white-on-*.
        let glyph = tintedSFIcon(
            symbol,
            color: base.isTemplate ? .black : .white,
            pointSize: 11
        )

        let gap: CGFloat = 2
        let size = NSSize(
            width:  base.size.width + gap + glyph.size.width,
            height: max(base.size.height, glyph.size.height)
        )

        let result = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(
                x: 0,
                y: (size.height - base.size.height) / 2,
                width: base.size.width,
                height: base.size.height
            ))

            glyph.draw(
                in: NSRect(
                    x: base.size.width + gap,
                    y: (size.height - glyph.size.height) / 2,
                    width: glyph.size.width,
                    height: glyph.size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: fraction
            )

            return true
        }

        result.isTemplate = base.isTemplate
        return result
    }

    /// Renders an SF Symbol as a non-template image in an explicit colour.
    private static func tintedSFIcon(
        _ name: String,
        color: NSColor,
        pointSize: CGFloat = 14
    ) -> NSImage {
        let sizeCfg  = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let colorCfg = NSImage.SymbolConfiguration(paletteColors: [color])
        let cfg      = sizeCfg.applying(colorCfg)
        let img      = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()

        img.isTemplate = false
        return img
    }

    /// `NSFont`'s factory methods are imported as non-optional, but they can
    /// still hand back nil (font server hiccup on a long-lived process, seen
    /// after sleep/wake). Swift stores that nil in a non-optional reference
    /// without complaining, and it only aborts much later — when CoreText
    /// copies the attributes dictionary during `NSString.draw`, as
    /// `-[__NSPlaceholderDictionary initWithObjects:forKeys:count:]: attempt
    /// to insert nil object`. A raw-pointer check is the only way to spot it,
    /// since `??` doesn't apply to a value the compiler thinks can't be nil.
    private static func resolved(_ font: NSFont) -> NSFont? {
        unsafeBitCast(font, to: UnsafeRawPointer?.self) == nil ? nil : font
    }

    /// Attributes for the menu-bar text badge, with a nil-safe font.
    ///
    /// The `.font` key is dropped entirely when every candidate comes back
    /// nil: CoreText then falls back to its own default face, which is a badly
    /// drawn icon for one frame instead of a crash.
    private static func labelAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]

        let font = resolved(NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold))
            ?? resolved(NSFont.systemFont(ofSize: 11, weight: .semibold))
            ?? resolved(NSFont.boldSystemFont(ofSize: 11))

        if let font {
            attrs[.font] = font
        }

        return attrs
    }

    /// Renders a short text label (e.g. "5G", "4G") as a menu-bar image.
    ///
    /// - `color`:           Tints the text; `nil` produces a template image.
    /// - `backgroundColor`: When set, draws a rounded filled box in that colour
    ///                      with white text — used for alert states (battery low,
    ///                      high data usage) instead of coloured text.
    /// - `badgeSymbol`:     SF Symbol drawn inside the box, right of the label.
    ///                      Ignored without a `backgroundColor`.
    private static func textIcon(
        _ label: String,
        color: NSColor? = nil,
        backgroundColor: NSColor? = nil,
        badgeSymbol: String? = nil
    ) -> NSImage {
        let sizeAttrs = labelAttributes(color: .black)

        let nsLabel  = label as NSString
        let textSize = nsLabel.size(withAttributes: sizeAttrs)

        let hPad: CGFloat = backgroundColor != nil ? 6 : 1
        let vPad: CGFloat = backgroundColor != nil ? 2 : 0

        // Glyph sits inside the box, right of the label — full opacity, like the
        // label itself, since the badge colour already carries the alert.
        let glyph: NSImage? = backgroundColor != nil
            ? badgeSymbol.map { tintedSFIcon($0, color: .white, pointSize: 11) }
            : nil
        let glyphGap: CGFloat = glyph != nil ? 2 : 0

        let imgSize = NSSize(
            width:  ceil(textSize.width) + glyphGap + (glyph?.size.width ?? 0) + hPad * 2,
            height: ceil(textSize.height) + vPad * 2
        )

        let image = NSImage(size: imgSize, flipped: false) { _ in
            if let bg = backgroundColor {
                // Resolve text colour inside the drawing closure so
                // NSAppearance.current reflects the actual rendering context.
                let drawAttrs = labelAttributes(color: .white)

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

                if let glyph {
                    glyph.draw(
                        in: NSRect(
                            x: hPad + ceil(textSize.width) + glyphGap,
                            y: (imgSize.height - glyph.size.height) / 2,
                            width: glyph.size.width,
                            height: glyph.size.height
                        ),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0
                    )
                }
            } else {
                let drawAttrs = labelAttributes(color: color ?? .black)

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
