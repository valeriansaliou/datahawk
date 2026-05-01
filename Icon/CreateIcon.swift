#!/usr/bin/env swift
// Generates AppIcon.icns from the SF Symbol "antenna.radiowaves.left.and.right"
// on a blueish linear gradient background.
// Usage: swift CreateIcon.swift  (run from the Icon/ directory)
// Output: AppIcon.icns (AppIcon.iconset/ is removed when done)

import AppKit

// NSApplication must be initialized for SF Symbols to load in a script context.
_ = NSApplication.shared

// MARK: - Config

let symbolName = "antenna.radiowaves.left.and.right"

// MARK: - Iconset slot definitions

struct Slot {
    let logical: Int   // logical size in points
    let scale:   Int   // 1x or 2x
    var pixels:  Int  { logical * scale }
    var filename: String {
        scale > 1
            ? "icon_\(logical)x\(logical)@\(scale)x.png"
            : "icon_\(logical)x\(logical).png"
    }
}

let slots: [Slot] = [
    Slot(logical: 16,  scale: 1), Slot(logical: 16,  scale: 2),
    Slot(logical: 32,  scale: 1), Slot(logical: 32,  scale: 2),
    Slot(logical: 128, scale: 1), Slot(logical: 128, scale: 2),
    Slot(logical: 256, scale: 1), Slot(logical: 256, scale: 2),
    Slot(logical: 512, scale: 1), Slot(logical: 512, scale: 2),
]

// MARK: - Rendering

func renderIcon(pixels px: Int) -> NSImage {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    defer { img.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
    let cs = CGColorSpaceCreateDeviceRGB()

    // Clip to rounded-rect (macOS app-icon corner ≈ 22% of size)
    let radius = s * 0.22
    let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // ── 1. Blueish linear gradient background (top → bottom) ─────────────
    let bgTop = CGColor(red: 0.22, green: 0.48, blue: 0.95, alpha: 1.0)  // vivid sky blue
    let bgBot = CGColor(red: 0.04, green: 0.14, blue: 0.62, alpha: 1.0)  // deep navy
    if let grad = CGGradient(colorsSpace: cs,
                              colors: [bgTop, bgBot] as CFArray,
                              locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: s / 2, y: s),
                               end:   CGPoint(x: s / 2, y: 0),
                               options: [])
    }

    // ── 2. SF Symbol (antenna) ────────────────────────────────────────────
    ctx.setBlendMode(.normal)
    let symPt = s * 0.48
    let cfg = NSImage.SymbolConfiguration(pointSize: symPt, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DataHawk")?
                     .withSymbolConfiguration(cfg),
       let cgSym = sym.cgImage(forProposedRect: nil, context: nil, hints: nil) {

        let symW = sym.size.width
        let symH = sym.size.height
        let symX = (s - symW) / 2
        let symY = (s - symH) / 2
        let symRect = CGRect(x: symX, y: symY, width: symW, height: symH)

        // Drop shadow beneath the symbol for depth.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: s * 0.006, height: -s * 0.012),
                      blur:   s * 0.025,
                      color:  CGColor(red: 0.0, green: 0.0, blue: 0.15, alpha: 0.45))
        ctx.beginTransparencyLayer(in: symRect, auxiliaryInfo: nil)

        // Clip to the symbol's alpha mask, then fill with white.
        ctx.clip(to: symRect, mask: cgSym)
        ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
        ctx.fill(symRect)

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    return img
}

// MARK: - PNG export

func savePNG(_ img: NSImage, to path: String) throws {
    guard let tiff   = img.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png    = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "create_icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG export failed: \(path)"])
    }
    try png.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

do {
    let iconset = "AppIcon.iconset"
    let fm = FileManager.default
    try? fm.removeItem(atPath: iconset)
    try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

    for slot in slots {
        let path = "\(iconset)/\(slot.filename)"
        try savePNG(renderIcon(pixels: slot.pixels), to: path)
        print("  \(slot.filename)  (\(slot.pixels)px)")
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconset, "-o", "AppIcon.icns"]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        fputs("iconutil failed\n", stderr)
        exit(1)
    }

    try? fm.removeItem(atPath: iconset)
    print("Created AppIcon.icns")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
