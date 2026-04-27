# CLAUDE.md — DataHawk

Developer context for Claude Code. Read this before making changes.

---

## Project overview

**DataHawk** is a native macOS menu bar app (Swift, no third-party dependencies) that monitors 5G mobile hotspots. It auto-detects when the Mac joins a known router's WiFi network via BSSID matching, then polls the router's admin API on a configurable interval and displays live metrics in a popover.

- **Bundle ID**: `com.datahawk.app`
- **Version**: 0.1.0
- **Min macOS**: 13.0 Ventura
- **Architectures**: arm64, x86_64 (auto-detected at build time)

---

## Build system

The project uses a plain `Makefile` with `xcrun swiftc` — no Xcode project, no Swift Package Manager for the binary itself (the `Package.swift` is only for LSP/SourceKit support).

```bash
make          # build .build/DataHawk.app
make all-dev  # build + kill existing process + reopen (use after every change)
make clean    # remove .build/
```

**Always run `make all-dev` after a successful build** to kill the running instance and reopen the app. The binary runs as a background agent (`LSUIElement = true`) so it doesn't appear in the Dock.

Code signing is optional and interactive. Pass `SIGN_ID` to skip the prompt:
```bash
make SIGN_ID="Developer ID Application: ..."
# or persist it:
echo 'export SIGN_ID=...' >> local.env   # local.env is gitignored via -include
```

All `.swift` files under `Sources/` are compiled in a single `swiftc` invocation — no incremental compilation.

---

## Source tree

```
Sources/
├── main.swift                          # Entry point (top-level code only here)
├── AppDelegate.swift                   # Lifecycle: login item, boots StatusBarController
├── AppState.swift                      # Single Combine ObservableObject (main-thread mutations)
│
├── Models/
│   ├── RouterMetrics.swift             # Value type: one poll cycle's worth of data
│   └── HotspotConfig.swift            # Codable config per router (stored in UserDefaults)
│
├── Services/
│   ├── ConfigStore.swift               # UserDefaults persistence for hotspots + options
│   ├── RouterService.swift             # Polling loop, FetchGate actor, error formatting
│   ├── WiFiMonitor.swift               # NWPathMonitor + CoreWLAN BSSID detection
│   └── LocationPermissionManager.swift # CLLocationManager wrapper (needed for bssid())
│
├── Providers/
│   ├── RouterProvider.swift            # Protocol + ProviderError
│   └── Netgear/
│       ├── NetgearProvider.swift       # Auth flow, cookie cache, URLSession factory
│       └── NetgearMetricsParser.swift  # model.json → RouterMetrics + JSON path helpers
│
└── UI/
    ├── StatusBarController.swift       # NSStatusItem + NSPopover + blink timer
    ├── IconRenderer.swift              # Generates NSImage for the status bar
    ├── PopoverView.swift               # Root SwiftUI view, HeaderSection, FooterSection
    ├── PopoverSections.swift           # ErrorBanner, Disconnected, Metrics, Alerts, Admin
    ├── PopoverComponents.swift         # DataUsageBar, SignalBarsView (reusable)
    ├── SettingsView.swift              # Hotspots tab + Options tab + form sheet
    ├── SettingsWindowController.swift  # Singleton NSWindow for settings
    └── WiFiQRWindowController.swift    # Singleton NSWindow for WiFi QR code
```

---

## Key architecture patterns

### State flow
`AppState` (singleton `ObservableObject`) is the single source of truth. All `@Published` mutations must happen on the **main thread** — callers use `DispatchQueue.main` or `MainActor.run`. SwiftUI views observe `AppState` via `@ObservedObject`.

### Connection lifecycle
```
WiFiMonitor.onNetworkChange
    → StatusBarController.checkConnection()
        → ConfigStore.hotspot(forBSSID:)
            → RouterService.start(with:)   # known hotspot
            → RouterService.stop()         # unknown / disconnected
```

### NETGEAR auth flow (full)
```
GET  /sess_cd_tmp         → anonymous Set-Cookie
GET  /api/model.json      → session.secToken (unauthenticated)
POST /Forms/config        → authenticated Set-Cookie  (can be slow: 60 s timeout)
GET  /api/model.json      → full metrics model
```

Fast path: inject cached cookies → single `GET /api/model.json`. Up to 2 attempts with 5 s timeout. Falls back to full auth if cookies are stale (`wwan.connection` absent) or both attempts time out.

### Single-flight gate
`FetchGate` is a Swift `actor` that prevents concurrent HTTP cycles from aborting each other. `RouterService.stop()` releases the gate via a fire-and-forget `Task` — safe because `stop()` also cancels the polling `Task`, so no new acquire can race ahead.

### Icon rendering
`IconRenderer` produces `NSImage` values for each state:

| State | Icon |
|---|---|
| `.disconnected` / `.failed` | Faded white antenna (35% opacity, non-template) |
| `.loading` | Template antenna (caller animates alpha via sine wave) |
| `.connected` — no signal | Faded white cellular bars (35% opacity, non-template) |
| `.connected` — normal | Text badge (`5G`, `4G`, …), template or tinted |
| `.connected` — battery low | Text badge, red tint |
| `.connected` — high data | Text badge, orange tint |

### BSSID detection
Two strategies, tried in order:
1. `CWInterface.bssid()` — requires Location Services ("always" auth).
2. `ipconfig getsummary <iface>` — no permission needed, reliable fallback.

BSSID matching normalises both sides to lowercase hex-only (strips colons/dashes) before comparing.

### URL normalisation (NETGEAR)
Bare IPv4 admin URLs (e.g. `http://10.0.2.1`) are rewritten to `http://mywebui`. The router's HTTP server validates the `Host` header and returns `sessionId=unknown` when addressed by IP.

---

## Adding a new router vendor

1. Add a case to `RouterVendor` (`Models/HotspotConfig.swift`).
2. Create `Sources/Providers/<Vendor>/` and implement `RouterProvider`:
   - `fetchMetrics(config:baseURL:) async throws -> RouterMetrics`
   - `flushAuth()` (if you cache auth state)
3. Register the provider in `RouterService.providers`.
4. Add a default base URL case in `RouterService.baseURL(for:)`.

---

## Known limitations / planned work

- **Credentials stored in plain text** in UserDefaults. Keychain migration needed before any public/App Store release.
- **Single vendor** (NETGEAR). Provider pattern is in place for others.
- **No incremental compilation** — every build recompiles all sources.
- **Location "always" permission** is requested, though "when in use" would suffice for foreground BSSID detection. This is a known over-ask.

---

## Coding conventions

- All `AppState` mutations on the main thread (no exceptions).
- New UI views go in `Sources/UI/`; split files when a file exceeds ~300 lines.
- New vendor providers go in `Sources/Providers/<VendorName>/`.
- Use `Task.sleep(for: .seconds(...))` not `Task.sleep(nanoseconds:)`.
- Prefer `guard` early-exits over nested `if let` chains.
- No third-party dependencies — Apple frameworks only.
- Run `make all-dev` to verify a build compiles and the app restarts cleanly.
