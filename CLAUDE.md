# CLAUDE.md — DataHawk

Developer context for Claude Code. Read this before making changes.

---

## Project overview

**DataHawk** is a native macOS menu bar app (Swift, no third-party dependencies) that monitors 5G mobile hotspots. It auto-detects when the Mac joins a known router's WiFi network via BSSID matching, then polls the router's admin API on a configurable interval and displays live metrics in a popover.

- **Bundle ID**: `com.datahawk.app`
- **Min macOS**: 26.0 Tahoe
- **Architecture**: arm64 (Apple Silicon only)

---

## Build system

The project uses a plain `Makefile` with `xcrun swiftc` — no Xcode project, no Swift Package Manager for the binary itself (the `Package.swift` is only for LSP/SourceKit support).

```bash
make app          # build DataHawk.app
make app-dev      # build + kill existing process + reopen (use after every change)
make dmg          # package DataHawk.app into DataHawk.dmg
make notarize     # notarize and staple an already-built DMG
make release      # full release: dmg + notarize (requires SIGN_ID)
make clean        # remove .build/ and build artefacts
```

**Always run `make app-dev` after a successful build** to kill the running instance and reopen the app. The binary runs as a background agent (`LSUIElement = true`) so it doesn't appear in the Dock.

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

## Key types

### Enums

**`ConnectionState`** (in `AppState.swift`) — `.disconnected`, `.loading`, `.failed`, `.connected`

**`NetworkType: String`** (in `AppState.swift`) — `.fiveG("5G")`, `.fourG("4G")`, `.threeG("3G")`, `.twoG("2G")`, `.oneG("1G")`, `.noSignal("No Signal")`, `.unknown("—")`

**`RouterVendor: String`** (in `HotspotConfig.swift`) — currently only `.netgear("NETGEAR")`

### Singletons

All singletons use `static let shared`:
- `AppState.shared` — runtime state (ObservableObject)
- `ConfigStore.shared` — UserDefaults persistence (ObservableObject)
- `RouterService.shared` — polling loop
- `LocationPermissionManager.shared` — CLLocationManager wrapper
- `SettingsWindowController.shared` — singleton NSWindow
- `WiFiQRWindowController.shared` — singleton NSWindow

### AppState published properties

- `connectionState: ConnectionState`, `activeHotspot: HotspotConfig?`, `lastUpdated: Date?`
- `metrics: RouterMetrics?`, `fetchError: String?`, `fetchingFromURL: String?`, `isFetching: Bool`
- `detectedBSSID: String?`, `detectedSSID: String?` (for debugging in disconnected view)

### RouterMetrics key properties

- **Cellular:** `networkType`, `technology` (raw API string), `connectionStatus`, `signalStrength` (0–5), `provider` (carrier), `isRoaming`
- **Data:** `dataUsedGB: Double?`, `dataLimitGB: Double?`, `dataHighUsageWarningPct: Int?`
- **Computed:** `dataUsagePercent: Double?` (0.0–1.0), `isHighDataUsage: Bool`
- **Battery:** `batteryPercent: Int?`, `isCharging: Bool`, `noBattery: Bool`, `batteryLowThreshold: Int` (default 20)
- **Computed:** `isPluggedIn: Bool` = `noBattery || isCharging`
- **WiFi:** `connectedUsers: Int`, `wifiEnabled: Bool`, `wifiSSID: String?`, `wifiPassphrase: String?`
- **Other:** `firmwareUpdateAvailable: Bool`, `adminURL: String`

### HotspotConfig properties

`id: UUID`, `name: String`, `macAddress: String`, `vendor: RouterVendor`, `username: String`, `password: String`, `customBaseURL: String?`
- **Computed:** `normalizedMAC` — lowercased hex-only (strips `:`, `-`, spaces)

---

## Key architecture patterns

### State flow
`AppState` (singleton `ObservableObject`) is the single source of truth. All `@Published` mutations must happen on the **main thread** — callers use `DispatchQueue.main` or `MainActor.run`. SwiftUI views observe `AppState` via `@ObservedObject`. This is **not** compiler-enforced (no `@MainActor` on `AppState`); violations crash Combine observers at runtime.

### Connection lifecycle
```
WiFiMonitor.onNetworkChange
    → StatusBarController.checkConnection()
        → ConfigStore.hotspot(forBSSID:)
            → RouterService.start(with:)   # known hotspot
            → RouterService.stop()         # unknown / disconnected
```

Also triggered by: `.datahawkSettingsDidClose` notification (user may have edited hotspots), LocationPermissionManager authorization change callback, and popover show (click on menu bar icon).

### Polling loop (RouterService)

`start(with:)` launches a `Task` that loops: fetch → sleep → repeat. Interval is read live from `ConfigStore.shared.refreshInterval` each cycle. On failure, uses shorter `retryInterval` (10 s) for fast recovery. `refresh()` triggers a one-off fetch; `forceFullRefresh()` flushes provider auth and restarts the loop.

### NETGEAR auth flow (full)
```
GET  /sess_cd_tmp         → anonymous Set-Cookie
GET  /api/model.json      → session.secToken (unauthenticated)
POST /Forms/config        → authenticated Set-Cookie  (can be slow: 60 s timeout)
GET  /api/model.json      → full metrics model
```

Fast path: inject cached cookies → single `GET /api/model.json`. Up to 2 attempts with 5 s timeout. Falls back to full auth if cookies are stale (`wwan.connection` absent) or both attempts time out (waits 10 s before fallback — router may be rebooting).

**Cookie cache:** stored in UserDefaults key `"netgear_cookies_v1"`, keyed by normalized base URL. Flushed via `flushAuth()`.

### Single-flight gate
`FetchGate` is a Swift `actor` that prevents concurrent HTTP cycles from aborting each other. `RouterService.stop()` releases the gate via a fire-and-forget `Task` — safe because `stop()` also cancels the polling `Task`, so no new acquire can race ahead.

### Error handling flow
```
RouterProvider throws ProviderError (human-readable) or URLError (transport)
  → RouterService.fetchAndPublish catches, converts via humanReadable()
    → AppState.fetchError set (UI shows red ErrorBannerSection)
    → If prior metrics exist: stays .connected (keeps stale data visible)
    → If no prior metrics: transitions to .failed
```

`humanReadable()` maps URLError codes to user-friendly strings (timedOut → "Connection timed out", cannotFindHost → "Router unreachable", etc.).

### Icon rendering
`IconRenderer` (enum, static methods only) produces `NSImage` values for each state:

| State | Icon |
|---|---|
| `.disconnected` / `.failed` | Faded white antenna (35% opacity, non-template) |
| `.loading` | Template antenna (caller animates alpha via sine wave) |
| `.connected` — no signal | Faded white cellular bars (35% opacity, non-template) |
| `.connected` — normal | Text badge (`5G`, `4G`, …), template or tinted |
| `.connected` — battery low | Text badge, red tint |
| `.connected` — high data | Text badge, orange tint (takes priority over battery low) |

Loading animation: `StatusBarController` runs a 0.1 s repeating `Timer`, accumulates phase (`2π / 14` per tick ≈ 1.4 Hz), alpha oscillates 0.4–1.0 via sine wave.

**Template vs non-template:** template images adapt to light/dark mode and menu-bar highlight. Non-template used for faded states (manual compositing) and colored badges.

### BSSID detection
Two strategies, tried in order:
1. `CWInterface.bssid()` — requires Location Services ("always" auth).
2. `ipconfig getsummary <iface>` — no permission needed, reliable fallback.

BSSID matching normalises both sides to lowercase hex-only (strips colons/dashes) before comparing. Falls back to `["en0", "en1"]` if CoreWLAN reports no interfaces.

### URL normalisation (NETGEAR)
Bare IPv4 admin URLs (e.g. `http://10.0.2.1`) are rewritten to `http://mywebui` via URLComponents host rewrite. The router's HTTP server validates the `Host` header and returns `sessionId=unknown` when addressed by IP. This is critical — without it, auth always fails.

### URLSession configuration
`makeFreshSession(requestTimeout:)` creates an **ephemeral** session each time (no shared state). Default request timeout: 8 s. Resource timeout: `max(requestTimeout + 4, 12)` s. Login POST to `/Forms/config` uses 60 s timeout (NETGEAR hardware is very slow here).

---

## Key constants and thresholds

| Constant | Value | Location |
|---|---|---|
| Min refresh interval | 5 s | ConfigStore |
| Max refresh interval | 3600 s | ConfigStore |
| Default refresh interval | 60 s | ConfigStore |
| Retry interval (after failure) | 10 s | RouterService |
| Fast-path timeout | 5 s (×2 attempts) | NetgearProvider |
| Full-auth request timeout | 8 s | NetgearProvider |
| Login POST timeout | 60 s | NetgearProvider |
| Wait after double timeout | 10 s | NetgearProvider |
| Battery low threshold (default) | 20% | RouterMetrics |
| Data bar: green→orange | 70% | DataUsageBar |
| Data bar: orange→red | 90% | DataUsageBar |
| Bytes per GB | 1,073,741,824 (1024³) | NetgearMetricsParser |
| Signal bars → percentage | ×20 (0–5 → 0–100%) | PopoverSections |
| Popover width | 280 pt | PopoverView |
| Settings window | 460×440 pt | SettingsWindowController |
| WiFi QR window | 300×360 pt | WiFiQRWindowController |
| Blink animation | 0.1 s timer, ~1.4 Hz, alpha 0.4–1.0 | StatusBarController |
| Copy-to-clipboard feedback | 2 s | DisconnectedSection, WiFiQRView |

---

## NETGEAR model.json parsing (NetgearMetricsParser)

Key JSON paths used in `extractMetrics(from:baseURL:)`:

| Metric | JSON path(s) | Notes |
|---|---|---|
| Network type | `wwan.connectionText` (primary), `wwan.currentNWserviceType` / `wwan.currentPSserviceType` (fallback) | Parsed via `parseNetworkType()` |
| Signal bars | `wwan.signalStrength.bars` | Clamped 0–5 |
| Carrier | `sim.SPN` (primary), `wwan.registerNetworkDisplay` (fallback) | |
| Roaming | `wwan.roamingType` | Case-insensitive compare to "Home" |
| Data used (bytes) | `wwan.dataUsage.generic.dataTransferred` (billing), `wwan.dataTransferred.totalb` / `rxb+txb` (session fallback) | Session values can be strings |
| Data limit | `wwan.dataUsage.generic.billingCycleLimit` | Conditional on `billingCycleLimitEnabled` or `billingCycleLimitRoaming` |
| Data warning % | `wwan.dataUsage.generic.usageHighWarning` | 0 treated as unconfigured |
| Battery state | `power.batteryState` | `"NoBattery"` = USB-C only device |
| Battery % | `power.battChargeLevel` | |
| Charging | `power.charging` | |
| Battery low threshold | `power.battLowThreshold` | Default 20 |
| Connected clients | `router.clientList.count` (primary), `wifi.clientCount` (fallback) | |
| Connection status | `wwan.connection` | Also used as auth check (absent = stale cookie) |
| Firmware update | `general.newFirmware` | Can be Bool, String "1", or Int 1 |

**JSON helpers** (extensions on `NetgearProvider`): `nestedValue(_:_:)` for dot-path traversal, `stringValue`, `numberValue`, `boolValue` with variadic path fallbacks, `doubleValue` / `stringToDouble` for type coercion.

---

## Popover view hierarchy

```
PopoverView (280 pt wide)
├─ HeaderSection — carrier + network badge + battery + refresh button + roaming pill
├─ [if high data] HighDataUsageAlertSection (orange banner)
├─ [if error] ErrorBannerSection (red banner)
├─ [if disconnected] DisconnectedSection (settings prompt + detected BSSID)
├─ [if metrics] MetricsSection (3 groups: cellular, wifi, data usage)
├─ [if metrics] AdminButtonSection (Open Admin UI + QR code)
├─ [if firmware update] FirmwareAlertSection (orange banner)
└─ FooterSection — Settings + Quit
```

**Refresh button:** plain click = `RouterService.refresh()`, Option-click = `RouterService.forceFullRefresh()` (full re-auth).

**Settings window:** `SettingsView` with TabView (Hotspots tab + Options tab). Hotspot form is a sheet (`HotspotFormView`). Save disabled if name/MAC/username empty. Window posts `.datahawkSettingsDidClose` on close → `StatusBarController.checkConnection()`.

**WiFi QR window:** `WiFiQRView` generates QR via CIQRCodeGenerator (WPA format: `WIFI:S:<ssid>;T:WPA;P:<passphrase>;;`, medium error correction, 10× scale). Shows password with show/hide toggle and copy button.

---

## Adding a new router vendor

1. Add a case to `RouterVendor` (`Models/HotspotConfig.swift`).
2. Create `Sources/Providers/<Vendor>/` and implement `RouterProvider`:
   - `fetchMetrics(config:baseURL:) async throws -> RouterMetrics`
   - `flushAuth()` (if you cache auth state)
3. Register the provider in `RouterService.providers`.
4. Add a default base URL case in `RouterService.baseURL(for:)`.

---

## Gotchas

- **AppState main-thread rule is not compiler-enforced.** No `@MainActor` annotation; callers must use `DispatchQueue.main` or `MainActor.run`. Violation → Combine crash at runtime.
- **ConfigStore.refreshInterval clamping triggers `didSet` twice.** Second pass is a no-op (value already clamped). Not a bug.
- **NETGEAR IP → hostname rewrite is mandatory.** Without `http://mywebui`, the router rejects auth. Check `normalizedBase()` in `NetgearProvider` when debugging auth failures.
- **NETGEAR data values can arrive as strings.** Session counters (`wwan.dataTransferred.totalb`) are strings like `"762096481"`, not numbers. Use `stringToDouble()`.
- **NETGEAR firmware flag is polymorphic.** Can be `Bool`, `"1"`, or `1`. Handled by `parseFirmwareFlag()`.
- **PopoverComponents (`DataUsageBar`, `SignalBarsView`) exist but are not currently used** in the popover sections. They're available for future use.
- **Popover positioning requires manual KVO workaround.** NSPopover positions incorrectly for status items due to flipped coordinates. `StatusBarController` repositions the window and observes frame changes to re-lock Y position.
- **WiFiQRWindowController releases window on close** (`window = nil` in `windowWillClose`), unlike `SettingsWindowController` which reuses.
- **`isPluggedIn` includes `noBattery` devices.** A router with no battery slot (USB-C only, always on external power) returns `noBattery = true`, `isCharging = false`. `isPluggedIn` handles this.
- **`isHighDataUsage` returns false if threshold is 0 or nil.** A threshold of 0 from the API means "unconfigured", not "always warn".

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
