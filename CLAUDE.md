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
│   ├── HotspotConfig.swift             # Codable config per router (stored in UserDefaults)
│   └── SessionRecord.swift             # SessionRecord + SessionLocation value types
│
├── Services/
│   ├── ConfigStore.swift               # UserDefaults persistence for hotspots + options
│   ├── RouterService.swift             # Polling loop, FetchGate actor, error formatting
│   ├── WiFiMonitor.swift               # NWPathMonitor + CoreWLAN BSSID detection
│   ├── LocationPermissionManager.swift # CLLocationManager wrapper (needed for bssid())
│   ├── UpdateChecker.swift             # Polls GitHub Releases for newer DMGs
│   ├── UpdateInstaller.swift           # Download + DMG mount + replace-app-bundle flow
│   ├── NotificationManager.swift       # UNUserNotificationCenter auth + transition-based alert dispatch
│   ├── SessionStore.swift              # JSONL append-only WAL for SessionRecord values
│   ├── SessionTracker.swift            # Combine pipelines: open/close sessions, sample signal, fix location
│   └── ClusterCache.swift              # Pre-computed map clusters with delta + background-rebuild updates
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
    ├── SessionsView.swift              # Map + List tabs, searchable Table, CSV export
    ├── SessionsWindowController.swift  # Singleton NSWindow for session history
    └── WiFiQRWindowController.swift    # Singleton NSWindow for WiFi QR code
```

---

## Key types

### Enums

**`ConnectionState`** (in `AppState.swift`) — `.noHotspot`, `.disconnected`, `.loading`, `.failed`, `.connected`. Helper: `isHotspotKnown` (true for everything except `.noHotspot`).

**`NetworkType: String`** (in `AppState.swift`) — `.fiveG("5G")`, `.fourG("4G")`, `.threeG("3G")`, `.twoG("2G")`, `.oneG("1G")`, `.noSignal("No Signal")`, `.unknown("Unknown")`

**`RouterVendor: String`** (in `HotspotConfig.swift`) — currently only `.netgear("NETGEAR")`

### Singletons

All singletons use `static let shared`:
- `AppState.shared` — runtime state (ObservableObject)
- `ConfigStore.shared` — UserDefaults persistence (ObservableObject)
- `RouterService.shared` — polling loop
- `LocationPermissionManager.shared` — CLLocationManager wrapper
- `SessionStore.shared` — JSONL session persistence (ObservableObject)
- `SessionTracker.shared` — Combine pipelines for open/close + signal sampling + location
- `ClusterCache.shared` — pre-computed map clusters (ObservableObject)
- `SettingsWindowController.shared` — singleton NSWindow
- `SessionsWindowController.shared` — singleton NSWindow for session history
- `WiFiQRWindowController.shared` — singleton NSWindow
- `UpdaterWindowController.shared` — singleton NSWindow for the update download/install flow

`UpdateChecker` is a stateless `enum` namespace, not a singleton — call its static methods directly: `UpdateChecker.checkForUpdates()` and `UpdateChecker.checkForUpdatesManually(...)`.

`NotificationManager.shared` — started once at launch via `start()`. Watches `ConfigStore` flags and `AppState.$metrics` via Combine; requests `UNUserNotificationCenter` authorization only when the user enables at least one alert. Never requests permission at launch.

`SessionTracker.shared` — started once at launch via `start()`. Closes orphans from the previous run unconditionally, then subscribes to `ConfigStore.$recordSessionHistory`, `AppState.$connectionState`, and `AppState.$metrics`. Owns a `CLLocationManager` for one-shot fixes and a 10-minute polling `Timer` to detect significant movement. Closes the active session cleanly via `closeOnTermination()` from `applicationWillTerminate`.

### AppState published properties

- `connectionState: ConnectionState`, `activeHotspot: HotspotConfig?`, `lastUpdated: Date?`
- `metrics: RouterMetrics?`, `fetchError: String?`, `fetchingFromURL: String?`, `isFetching: Bool`
- `detectedBSSID: String?`, `detectedSSID: String?` (for debugging in disconnected view)
- `updateDownloadURL: String?` — set by `UpdateChecker` when a newer release is available; cleared by `UpdaterWindowController` after install

### RouterMetrics key properties

- **Cellular:** `networkType`, `technology` (raw API string), `connectionStatus`, `signalStrength` (0–5), `provider` (carrier), `isRoaming`, `isSimLocked`
- **Computed:** `isRouterConnected: Bool` (case-insensitive "Connected" check on `connectionStatus`)
- **Data:** `dataUsedGB: Double?`, `dataLimitGB: Double?`, `dataHighUsageWarningPct: Int?`
- **Computed:** `dataUsagePercent: Double?` (0.0–1.0), `isHighDataUsage: Bool`
- **Battery:** `batteryPercent: Int?`, `isCharging: Bool`, `noBattery: Bool`, `batteryLowThreshold: Int` (default 20)
- **Computed:** `isPluggedIn: Bool` = `noBattery || isCharging`; `isBatteryLow: Bool` (true only when on battery and below threshold)
- **WiFi:** `connectedUsers: Int`, `wifiEnabled: Bool`, `wifiSSID: String?`, `wifiPassphrase: String?`
- **Other:** `firmwareUpdateAvailable: Bool`, `adminURL: String`

Use the computed predicates (`isBatteryLow`, `isRouterConnected`, `isPluggedIn`, `isHighDataUsage`) instead of recomputing them at view sites — both `PopoverView` and `StatusBarController` rely on them.

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

Fast path: inject cached cookies → single `GET /api/model.json`. Up to 2 attempts with 5 s timeout. The helper `tryFastPath(cookies:base:)` returns a `FastPathResult` enum:
- `.success(RouterMetrics)` — happy path.
- `.stale` — router replied but the cookie is rejected (`wwan.connection` absent) or another non-timeout error: drop the cookie and proceed to full auth immediately.
- `.timedOut` — both attempts ran out of time: drop the cookie, sleep 10 s (router may be rebooting), then run full auth.

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
| `.noHotspot` | Slashed antenna at full opacity (template) |
| `.disconnected` / `.failed` | Faded white antenna (35% opacity, non-template) |
| `.loading` | Template antenna (caller animates alpha via sine wave) |
| `.connected` — SIM locked | Orange `simcard` icon (takes priority over network type) |
| `.connected` — no signal | Faded white cellular bars (35% opacity, non-template) |
| `.connected` — router not connected | Faded text badge (35% opacity) — `connectionStatus != "Connected"` |
| `.connected` — high data | Text badge, orange tint (takes priority over battery low) |
| `.connected` — battery low | Text badge, red tint |
| `.connected` — normal | Text badge (`5G`, `4G`, …), template |

The 35%-opacity overlay is produced by a single private helper `IconRenderer.faded(_:fraction:)` reused by `loadingIcon(alpha:)`.

Loading animation: `StatusBarController` runs a 0.1 s repeating `Timer`, accumulates phase (`2π / 14` per tick ≈ 1.4 Hz), alpha oscillates 0.4–1.0 via sine wave.

**Icon update subscription:** `setupStateObserver` subscribes to `AppState.shared.$connectionState.combineLatest($metrics)` and recomputes the icon on every emission. `metrics` is replaced wholesale on every fetch, so observing the two top-level publishers captures every relevant transition without nested `CombineLatest`.

**Template vs non-template:** template images adapt to light/dark mode and menu-bar highlight. Non-template used for faded states (manual compositing) and colored badges.

### BSSID detection
Two strategies, tried in order:
1. `CWInterface.bssid()` — requires Location Services ("always" auth).
2. `ipconfig getsummary <iface>` — no permission needed, reliable fallback.

BSSID matching normalises both sides to lowercase hex-only (strips colons/dashes) before comparing. Falls back to `["en0", "en1"]` if CoreWLAN reports no interfaces.

### URLSession configuration
`makeFreshSession(requestTimeout:)` creates an **ephemeral** session each time (no shared state). Default request timeout: 8 s. Resource timeout: `max(requestTimeout + 4, 12)` s. Login POST to `/Forms/config` uses 60 s timeout (NETGEAR hardware is very slow here).

### Notification flow

`NotificationManager.start()` sets up two independent Combine pipelines on `AppState.$metrics` using `.scan` to pair consecutive values `(previous, current)`. Each pipeline checks for a specific state transition and fires a `UNNotificationRequest` with a fixed identifier (so repeated events replace rather than stack in Notification Center):

| Event | Transition | Identifier |
|---|---|---|
| Battery low | `isBatteryLow` false → true | `com.datahawk.battery-low` |
| Signal lost | `networkType` non-`.noSignal` → `.noSignal` | `com.datahawk.no-signal` |

Both are gated by their respective `ConfigStore` flags (`notifyBatteryLow`, `notifyNoService`). Authorization is requested lazily — only when a flag is first toggled on and the status is still `.notDetermined`. The `OptionsTab` footer reflects the current `UNAuthorizationStatus`: hidden when authorized, red warning when denied with a toggle on, grey hint when not yet determined.

### Session tracking flow

Opt-out feature controlled by `ConfigStore.recordSessionHistory` (default true). `SessionTracker.start()` boots in `applicationDidFinishLaunching` after `NotificationManager.start()`.

**Session lifecycle:**
```
AppState.$connectionState (scan → previous, current)
    ↳ noHotspot/disconnected/failed/loading → .connected   ⇒ openSession()
    ↳ .connected → anything else                            ⇒ closeActiveSession()
```

`openSession` snapshots `provider`, `generation`, `isRoaming`, `dataStartGB` from `AppState.metrics`, seeds `signalSamples` with the current bar count, then calls `requestLocationFix()` and starts a 10-minute repeating timer.

`closeActiveSession` stamps `endDate = Date()` and snapshots `dataEndGB`, then upserts. `closeOnTermination()` is called from `applicationWillTerminate` so clean exits flush the active session.

**Signal sampling:** every `AppState.$metrics` emission appends `signalStrength` to `signalSamples` on the active session. Persisted on a fixed 5-minute cadence (`samplePersistInterval`) — independent of the user's refresh interval — so a 5 s polling interval doesn't write 12 lines/minute to the JSONL file.

**Location:** one-shot `CLLocationManager.requestLocation()` at session open. Stores the first fix as the session anchor. Every 10 minutes a fresh fix is requested; if it's >100 m from the anchor (`locationChangeDist`), the session is split — `closeActiveSession()` followed by `openSession()`. The geocoded name is fetched via `CLGeocoder.reverseGeocodeLocation` and applied to the active session **only if its ID still matches** the one captured at the time of the request (guards against a stale callback overwriting a session that was split during the geocode).

**Crash recovery:** `closeOrphanedSessions()` runs at every launch (unconditionally — orphans should be finalised even when the toggle is currently off). Stamps `endDate = Date()` on any open session left by a previous run.

**Persistence (JSONL WAL):** `SessionStore` writes append-only JSON Lines to `~/Library/Application Support/DataHawk/sessions.jsonl`. Each upsert appends one line for the session's UUID; `load()` collapses duplicates with last-write-wins. `compact()` rewrites the file from the in-memory deduplicated list and triggers `ClusterCache.rebuild()`. Triggered by `wipeSession*` calls and by `trimIfNeeded()` (kicks in at 10% over the configured `maxSessionCount`, drops the oldest 10% of completed sessions in a batch).

**Cluster cache:** `ClusterCache` persists pre-computed map clusters to `clusters.json`. Two update paths:
- `updateForSession(_:)` — delta update, O(clusters), called on every `SessionStore.upsert`. Skipped while a rebuild is in flight; sets `rebuildDirty` so the in-flight delta isn't lost.
- `rebuild()` — full recompute on a background `Task.detached(priority: .utility)`. Result is posted back to the main actor. If `rebuildDirty` was set during the rebuild, schedules a follow-up rebuild.

Cluster centre coordinates are the first session that founded the cluster; the cluster's `id` and `latestSignal`/`latestGeneration` track the newest representative session for pin styling and tap navigation. Two sessions are merged into the same cluster when within `distanceThreshold` (20 m).

### Update flow
`UpdateChecker` (enum namespace) hits the GitHub Releases API for `valeriansaliou/datahawk` and finds the first asset whose name ends with `.dmg`. Two entry points:
- `checkForUpdates()` — called once at launch with a 5 s delay. Silent; sets `AppState.updateDownloadURL` if a newer release exists, which lights up `UpdateAvailableSection` in the popover.
- `checkForUpdatesManually(onFound:onUpToDate:onError:)` — used by the About tab; reports via callbacks on the main thread.

Version comparison: `versionComponents(_:)` strips a leading `v`, splits on `.`, and compares element-wise (missing components treated as 0).

`UpdateInstaller` / `UpdaterWindowController.shared` runs the install flow: shows a progress window, downloads the DMG via `URLSessionDownloadTask` delegate callbacks, then on completion mounts via `hdiutil attach`, copies `.app` to a `DataHawk.staged.app` sibling, swaps in via `FileManager.replaceItemAt`, detaches the volume, and prompts the user to restart. Restart spawns a detached `/bin/sh -c 'sleep 0.5 && open <bundle>'` then calls `NSApp.terminate`.

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
| Notify battery low (default) | false | ConfigStore |
| Notify no signal (default) | false | ConfigStore |
| Record session history (default) | true (opt-out) | ConfigStore |
| Max session count (default) | 10,000 (clamped 100–1,000,000) | ConfigStore |
| Session trim trigger | count > 110% of limit | SessionStore |
| Session trim batch | drop 10% of limit | SessionStore |
| Signal sample persist interval | 300 s (5 min) | SessionTracker |
| Session location poll interval | 600 s (10 min) | SessionTracker |
| Session split distance threshold | 100 m | SessionTracker |
| Cluster merge distance threshold | 20 m | ClusterCache |
| Signal bars → percentage | ×20 (0–5 → 0–100%) | PopoverSections |
| Popover width | 280 pt | PopoverView |
| Settings window | 460×540 pt | SettingsWindowController |
| Sessions window | 1248×748 (capped at 92% of screen), min 750×540 | SessionsWindowController |
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
├─ [if metrics] AdminButtonSection (Open Admin UI + Sessions map + QR code)
├─ [if firmware update] FirmwareAlertSection (orange banner)
├─ [if app update] UpdateAvailableSection (accent-coloured banner with Install button)
└─ FooterSection — Settings + Quit
```

The Sessions map button in `AdminButtonSection` is conditional on `ConfigStore.recordSessionHistory`; clicking it posts `.datahawkHidePopover` and shows `SessionsWindowController.shared`.

**Refresh button:** plain click = `RouterService.refresh()`, Option-click = `RouterService.forceFullRefresh()` (full re-auth).

**Status-bar Option-click:** opens the WiFi QR sheet directly (skipping the popover) when a known hotspot is connected and WiFi credentials are available. Implemented in `StatusBarController.handleClick(_:)`.

**Settings window:** `SettingsView` with TabView (Hotspots tab + Options tab). Hotspot form is a sheet (`HotspotFormView`). Save disabled if name/MAC/username empty. Window posts `.datahawkSettingsDidClose` on close → `StatusBarController.checkConnection()`.

**Sessions window:** `SessionsView` with a segmented Map/List picker.
- **Map tab** (`SessionMapView`): observes `ClusterCache.shared.clusters`. Initial camera is fitted to all clusters with 1.8× padding (single cluster uses a fixed 0.12° span). Pins are circular and coloured by `latestSignal` (green ≥ 4, yellow 3–4, orange 2–3, red 1–2, gray otherwise). Tapping a pin selects the cluster's representative session and switches to the List tab.
- **List tab** (`SessionListView`): SwiftUI `Table` with sortable columns, free-text search across geocoded name / coordinates / provider / ISO date / locale-short date, context menu (Copy as Text, Copy GPS, Delete), and a toolbar (Start New Session, Export CSV, Wipe All).
- **Hotspot resolution:** the Hotspot column resolves `hotspotBSSID` against `ConfigStore.hotspot(forBSSID:)` at display time, so renaming a hotspot retroactively updates every row. Removed hotspots render as a tertiary-coloured "Removed hotspot".

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
- **`@MainActor` on `AppState`/`ConfigStore` is blocked by a background read.** `RouterService.pollInterval` reads `ConfigStore.shared.refreshInterval` from a detached polling `Task` (`Sources/Services/RouterService.swift`), so adding actor isolation would require restructuring the polling loop first. Don't slap `@MainActor` on these without addressing that read.
- **`HotspotConfig.id` must be `var`, not `let`.** SwiftC warns: "Immutable property will not be decoded because it is declared with an initial value which cannot be overwritten." With `let id = UUID()`, JSON-stored ids are silently dropped and a fresh UUID is generated on every decode — a real data-corruption hazard. Keep `var id = UUID()` for round-trip Codable behavior.
- **ConfigStore.refreshInterval clamping triggers `didSet` twice.** Second pass is a no-op (value already clamped). Not a bug.
- **NETGEAR data values can arrive as strings.** Session counters (`wwan.dataTransferred.totalb`) are strings like `"762096481"`, not numbers. Use `stringToDouble()`.
- **NETGEAR firmware flag is polymorphic.** Can be `Bool`, `"1"`, or `1`. Handled by `parseFirmwareFlag()`.
- **PopoverComponents (`DataUsageBar`, `SignalBarsView`) exist but are not currently used** in the popover sections. They're available for future use.
- **Popover positioning requires manual KVO workaround.** NSPopover positions incorrectly for status items due to flipped coordinates. `StatusBarController` repositions the window and observes frame changes to re-lock Y position.
- **WiFiQRWindowController releases window on close** (`window = nil` in `windowWillClose`), unlike `SettingsWindowController` which reuses.
- **`isPluggedIn` includes `noBattery` devices.** A router with no battery slot (USB-C only, always on external power) returns `noBattery = true`, `isCharging = false`. `isPluggedIn` handles this.
- **`isHighDataUsage` returns false if threshold is 0 or nil.** A threshold of 0 from the API means "unconfigured", not "always warn".
- **`SessionRecord.id` must be `var`, not `let`.** Same Codable / `init(from:)` issue as `HotspotConfig.id` — a `let id = UUID()` is silently dropped on decode and a new UUID is generated each load, corrupting the WAL's last-write-wins dedup.
- **`ClusterCache.rebuild()` swallows updates without `rebuildDirty`.** Background-snapshot rebuilds overwrite any delta from `updateForSession()` that lands while they're running. `rebuildDirty` triggers a follow-up rebuild so nothing is lost. Don't remove this flag.
- **`SessionStore.upsert` during rebuild calls `updateForSession`, which is a no-op.** The follow-up rebuild picks the new session up from the fresh `SessionStore.sessions` snapshot — eventually consistent, not immediately.
- **Geocoder callback can outlive its session.** `SessionTracker.locationManager(_:didUpdateLocations:)` captures the session ID before calling `geocode(...)` and bails in the callback if `activeSession?.id` no longer matches. Without this, a slow geocode for a *previous* session would stamp its name onto whatever session is active when the callback fires. The geocoded name for the original session is lost (rare, since geocoding usually completes in 1–3 s and the move threshold is 100 m).
- **`closeOrphanedSessions()` runs unconditionally at launch.** It does NOT gate on `recordSessionHistory`, otherwise orphans get stranded forever once the user turns the toggle off.
- **macOS location-auth check is `.authorizedAlways` only.** `.authorized` is a deprecated iOS alias; `.authorizedWhenInUse` doesn't exist on macOS. Don't add either back to `isLocationAuthorized`.
- **JSONL append on main thread.** `SessionStore.appendLine` does synchronous file I/O on the main thread. Writes are small (one JSON line) so latency is sub-millisecond on local disk — acceptable for now. If profiling ever shows this on a hot path, move to a serial background queue.
- **CSV `Duration` column has a dead em-dash branch.** `session.duration == nil` iff `endDate == nil` iff `isActive == true`, so the `"\u{2014}"` fallback is unreachable. Kept as a defensive default.

---

## Known limitations / planned work

- **Credentials stored in plain text** in UserDefaults. Keychain migration needed before any public/App Store release.
- **Single vendor** (NETGEAR). Provider pattern is in place for others.
- **No incremental compilation** — every build recompiles all sources.
- **Location "always" permission** is requested, though "when in use" would suffice for foreground BSSID detection. This is a known over-ask.
- **`CLGeocoder` is deprecated on macOS 26.** `SessionTracker.geocode(...)` still uses it; migration to `MKReverseGeocodingRequest` is deferred until the replacement API stabilises post-WWDC 2025. A deprecation warning at build time is expected.
- **Sessions table doesn't auto-scroll on selection.** Tapping a map pin selects the session and switches to the List tab, but the SwiftUI `Table` does not scroll the selected row into view — the user may need to scroll manually.

---

## Coding conventions

- All `AppState` mutations on the main thread (no exceptions).
- Mark non-inheritable classes `final` (every concrete class in the project currently is).
- Prefer typed result enums (`FastPathResult`, `ReleaseResult`) over `(success:Bool, error:Error?)` tuples or sentinel booleans.
- Add derived state as a computed property on the model (see `RouterMetrics.isBatteryLow` / `isRouterConnected`) rather than recomputing in views or services.
- Drop redundant `= nil` on optional `@Published` properties — Swift defaults them to `nil`.
- New UI views go in `Sources/UI/`; split files when a file exceeds ~300 lines.
- New vendor providers go in `Sources/Providers/<VendorName>/`.
- Use `Task.sleep(for: .seconds(...))` not `Task.sleep(nanoseconds:)`.
- Prefer `guard` early-exits over nested `if let` chains.
- No third-party dependencies — Apple frameworks only.
- Run `make app-dev` to verify a build compiles and the app restarts cleanly.
