import AppKit

/// Generates the NSImage shown in the macOS status bar.
/// All images are template images so they adapt automatically to
/// light / dark mode and the highlighted (blue) menu bar state.
enum IconRenderer {
    static func icon(state: ConnectionState, networkType: NetworkType?, batteryLow: Bool = false) -> NSImage {
        switch state {
        case .disconnected:
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
            let type = networkType ?? .unknown
            switch type {
            case .noSignal:
                return sfSymbol("exclamationmark.transmission")
            default:
                return batteryLow
                    ? textIcon(type.rawValue, color: .systemRed)
                    : textIcon(type.rawValue)
            }
        }
    }

    /// Loading icon at a specific opacity (0.0–1.0) for smooth blink animation.
    /// Draws a fully-opaque white icon composited at `fraction` so the
    /// opacity is applied straightforwardly without palette-colour quirks.
    static func loadingIcon(alpha: CGFloat = 1.0) -> NSImage {
        let clamped = max(0.0, min(1.0, alpha))
        let base    = whiteIcon("antenna.radiowaves.left.and.right")
        if clamped >= 0.99 { return base }
        let result  = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: clamped)
            return true
        }
        result.isTemplate = false
        return result
    }

    /// Fully-opaque white version of an SF Symbol (non-template).
    private static func whiteIcon(_ name: String) -> NSImage {
        tintedSFIcon(name, color: .white)
    }

    // MARK: - Helpers

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
        let sizeCfg    = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let colorCfg   = NSImage.SymbolConfiguration(paletteColors: [color])
        let cfg        = sizeCfg.applying(colorCfg)
        let img        = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = false
        return img
    }

    /// Renders a short text label (e.g. "5G", "4G") as a menu-bar image.
    /// Pass a color for a non-template colored icon; nil gives a template image.
    private static func textIcon(_ label: String, color: NSColor? = nil) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color ?? .black,
        ]
        let nsLabel  = label as NSString
        let textSize = nsLabel.size(withAttributes: attrs)
        let imgSize  = NSSize(width: ceil(textSize.width) + 2, height: ceil(textSize.height))

        let image = NSImage(size: imgSize, flipped: false) { rect in
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
