# DataHawk

**DataHawk** is a lightweight macOS menu bar app that monitors your 5G mobile hotspot in real time. It sits quietly in the status bar and displays live cellular metrics — signal strength, data usage, battery level, and more — fetched directly from your router's admin API.

✅ Supported hotspots:

- **NETGEAR**
  - **Nighthawk** (M3, M6, M6 Pro).
- _Want to add a hotspot vendor? We accept PRs!_

## Screenshots

![datahawk-screenshot-1](https://github.com/user-attachments/assets/07978787-c3e6-49d0-ab6a-0268f4e76c67)

## Features

- **Auto-detection** — connects automatically when your Mac joins a known hotspot's WiFi network
- **Live metrics** in the popover:
  - Cellular generation (5G / 4G / 3G / 2G / 1G / No Signal)
  - Signal strength (0–5 bars)
  - Carrier name
  - Connection status
  - Roaming indicator
  - Data used / Data limit / Data remaining
  - Battery level and charging state
  - WiFi network name and connected client count
  - Firmware update notification
- **Status bar icon** reflects the current state at a glance:
  - Text badge (`5G`, `4G`, …) when connected
  - Orange badge when data usage is high
  - Red badge when battery is low
  - Faded antenna when no hotspot is detected
  - Faded cellular bars when signal is lost
  - Blinking antenna while the first fetch is in progress
- **WiFi QR share** — Option-click the icon (or use the QR button) to show a scannable QR code for joining the router's WiFi
- **Auto-launch** at login
- No Dock icon, no menubar clutter — _pure status bar utility_

## Building

Requires Xcode Command Line Tools (`xcode-select --install`). No third-party dependencies.

```bash
# Clone the repo
git clone https://github.com/valeriansaliou/datahawk.git
cd datahawk

# Build DataHawk.app in the project root
make

# Build and launch immediately (kills any running instance first)
make all-dev

# Clean all build artefacts
make clean
```

`make` produces `DataHawk.app` in the project root. Drag it to `/Applications` to install.

### Code signing (optional)

Pass your Developer ID signing identity to skip the interactive prompt:

```bash
make SIGN_ID="Developer ID Application: Your Name (XXXXXXXXXX)"
```

Leave it empty to build without signing (works fine for local use). You can also persist it in a `local.env` file (gitignored):

```bash
echo 'export SIGN_ID="Developer ID Application: Your Name (XXXXXXXXXX)"' >> local.env
```

### Build from source

```bash
make app
```

Requires Xcode command line tools and a valid Developer ID for signing.

If you don't, you will be asked for your signature key identifier when building the app. 

### Release & notarize

👉 This procedure is only used by repository maintainers to release new versions of DataHawk.

1. Prior to distributing a release, create a new Git tag so that the new version is picked up during build. Tags should be formatted as such: `v1.0.0`.

2. Once tagged, you can build `DataHawk.app`:

```bash
make app
```

3. Finally, it needs to be packaged and notarized into `DataHawk.dmg` as such:

```bash
make release
```

4. When the final DMG has been packaged and notarized, simply draft a new release on [DataHawk/releases](https://github.com/valeriansaliou/datahawk/releases) and upload `DataHawk.dmg`.

👉 The website does not need to be updated, since the download button points to the `DataHawk.dmg` file from the latest release.

👉 You can configure your signing key by creating a `local.env` file with eg.:

```bash
export SIGN_ID=Developer ID Application: Your Developer Name (IDENTIFIER_HERE)
```

## Setup

1. Launch DataHawk — the antenna icon appears in the menu bar.
2. Grant **Location Services** permission when prompted (needed for WiFi BSSID detection).
3. Click the icon → **Settings** → **Hotspots** tab → **Add Hotspot**.
4. Fill in the details for your router:

| Field | Description |
|---|---|
| **Name** | A label you'll recognise, e.g. "Office M6 Pro" |
| **BSSID** | The MAC address of the router's WiFi radio (shown in the disconnected view if unknown) |
| **Vendor** | Router manufacturer (currently: NETGEAR) |
| **Username** | Router admin username |
| **Password** | Router admin password |
| **Admin URL** *(optional)* | Override the auto-detected admin URL, e.g. `http://192.168.1.1` |

5. Connect your Mac to that router's WiFi — DataHawk picks it up automatically.

### Finding your BSSID

The BSSID is the MAC address of the router's WiFi access point. When DataHawk is running but no hotspot is configured, the popover shows the **detected BSSID** of the current network with a copy button — paste it directly into the settings form.

Alternatively, find it in **System Settings → Wi-Fi → Details → BSSID**.

## Usage

| Action | Result |
|---|---|
| **Click** the icon | Open / close the metrics popover |
| **Click ↻** in the popover | Force a refresh of metrics |
| **Option-click ↻** | Force full refresh of metrics (re-authenticates) |
| **Option-click** the icon | Show WiFi QR code share window |
| **Click QR button** | Show WiFi QR code share window |
| **Click Settings** | Open the hotspot and options configuration window |

## License

MIT — see [LICENSE](LICENSE).
