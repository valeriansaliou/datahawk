import AppKit
import SwiftUI
import CoreImage

// MARK: - Window controller

class WiFiQRWindowController: NSObject, NSWindowDelegate {
    static let shared = WiFiQRWindowController()

    private var window: NSWindow?

    private override init() {}

    func show(ssid: String, passphrase: String) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view    = WiFiQRView(ssid: ssid, passphrase: passphrase)
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(
            contentRect : NSRect(x: 0, y: 0, width: 300, height: 360),
            styleMask   : [.titled, .closable],
            backing     : .buffered,
            defer       : false
        )
        win.title                 = "Connect to WiFi"
        win.contentViewController = hosting
        win.isReleasedWhenClosed  = false
        win.delegate              = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - QR code view

private struct WiFiQRView: View {
    let ssid       : String
    let passphrase : String

    @State private var passwordVisible = false
    @State private var copied          = false

    var body: some View {
        VStack(spacing: 20) {
            if let img = qrImage {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledRow(label: "Network") {
                    Text(ssid)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }

                LabeledRow(label: "Password") {
                    HStack(spacing: 6) {
                        if passwordVisible {
                            Text(passphrase)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                        } else {
                            Text(String(repeating: "•", count: min(passphrase.count, 16)))
                                .fontDesign(.monospaced)
                        }
                        Spacer(minLength: 0)
                        Button {
                            passwordVisible.toggle()
                        } label: {
                            Image(systemName: passwordVisible ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(passphrase, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(copied ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 300)
    }

    private var qrImage: NSImage? {
        let wifiString = "WIFI:S:\(ssid);T:WPA;P:\(passphrase);;"
        guard let data   = wifiString.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data,  forKey: "inputMessage")
        filter.setValue("M",   forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }

        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep    = NSCIImageRep(ciImage: scaled)
        let image  = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Helpers

private struct LabeledRow<Content: View>: View {
    let label   : String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
                .font(.system(size: 11))
        }
    }
}
