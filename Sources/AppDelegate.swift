import AppKit
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the app out of the Dock even if LSUIElement was somehow overridden.
        NSApp.setActivationPolicy(.accessory)

        // Register as a login item so the app launches automatically at login.
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Silently ignore — the app works fine even without auto-launch.
            print("[DataHawk] Login item registration failed: \(error.localizedDescription)")
        }

        statusBarController = StatusBarController()
        statusBarController.start()

        // CoreWLAN's bssid() requires Location Services on macOS 10.15+.
        // Request permission now; re-check the connection once it's granted
        // so the hotspot is recognised without needing a network change event.
        LocationPermissionManager.shared.onAuthorizationChange = { [weak self] in
            DispatchQueue.main.async { self?.statusBarController.checkConnection() }
        }
        LocationPermissionManager.shared.requestIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController.stop()
    }
}
