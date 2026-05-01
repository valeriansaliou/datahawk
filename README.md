# 📶 DataHawk

**DataHawk** is a lightweight macOS menu bar app that monitors your 5G mobile hotspot in real time.

It sits quietly in the status bar and displays live cellular metrics — signal strength, data usage, battery level, and more — fetched directly from your router's admin API. There's no Dock icon — _DataHawk is a pure status bar utility_.

⬇️ **[Download DataHawk for macOS](https://github.com/valeriansaliou/datahawk/releases/latest/download/DataHawk.dmg)**

## Supported hotspots

| Vendor | Supported Models | Feature Support |
|---|---|---|
| NETGEAR | Nighthawk M3, M6, M6 Pro | Full |

_💡 Want to [add a hotspot vendor](./Sources/Providers)? We accept PRs!_

## Screenshots

![DataHawk app menu](https://github.com/user-attachments/assets/07978787-c3e6-49d0-ab6a-0268f4e76c67)

## Features

- ✅ **Hotspot auto-detection** — connects automatically when your Mac joins a known hotspot's WiFi network
- ✅ **Live cellular metrics** in the popover:
  - Cellular generation (5G / 4G / 3G / 2G / 1G / No Signal)
  - Signal strength (0–5 bars)
  - Carrier name
  - Connection status
  - Roaming indicator
  - Data used / Data limit / Data remaining
  - Battery level and charging state
  - WiFi network name and connected client count
  - Firmware update notification
- ✅ **Status bar icon** reflects the current state at a glance:
  - Text badge (`5G`, `4G`, …) when connected
  - Orange badge when data usage is high
  - Red badge when battery is low
  - Faded antenna when no hotspot is detected
  - Faded cellular bars when signal is lost
  - Blinking antenna while the first router metrics fetch is in progress
- ✅ **WiFi QR share** — Option-click the icon (or use the QR button) to show a scannable QR code for joining the router's WiFi

## Install

Download the latest release from [GitHub Releases](https://github.com/valeriansaliou/datahawk/releases) and drag **DataHawk.app** into your Applications folder.

### Hotspot setup procedure

1. Launch DataHawk — the antenna icon appears in the menu bar.
2. Grant **Location Services** permission when prompted (needed for WiFi BSSID detection).
3. Click the icon → **Settings** → **Hotspots** tab → **Add Hotspot**.
4. Fill in the details for your router:

| Field | Description |
|---|---|
| **Name** | A label you'll recognise, eg. "Office M6 Pro" |
| **BSSID** | The MAC address of the router's WiFi radio (shown in the disconnected view if unknown) |
| **Vendor** | Router manufacturer (currently: NETGEAR) |
| **Username** | Router admin username |
| **Password** | Router admin password |
| **Admin URL** *(optional)* | Override the auto-detected admin URL, eg. `http://mywebui` for NETGEAR |

5. Connect your Mac to that router's WiFi — DataHawk will now show the information from your router in your macOS menu bar.

### Finding your WiFi BSSID

The BSSID is the MAC address of the router's WiFi access point. When DataHawk is running but no hotspot is configured, the popover shows the **detected BSSID** of the current network with a copy button — paste it directly into the settings form.

DataHawk uses the BSSID as a means to securely know when you are connected to a known hotspot. DataHawk only attempts to login to the router's administrator area for known BSSIDs, meaning your credentials are not sent to other WiFi routers (eg. your home fiber router, a public coffee shop, etc.).

⚠️ **Note that the WiFi BSSID is different for your 5GHz network and your 2.4GHz network**. When your MacBook gets far away from your router, then you might roam from 5GHz to 2.4GHz, therefore your BSSID will change. **You will need to configure a second BSSID in DataHawk** with the same credentials for your metrics to show properly on both 5GHz and 2.4GHz.

![2 hotspots for 5GHz and 2.4GHz WiFi](https://github.com/user-attachments/assets/880173d6-6e13-472d-b2ef-9d55cb20b1e5)
_You will need to add 2 separate hotspots to support both 5GHz WiFi and 2.4GHz._

## Uninstall

1. Quit DataHawk from the menu bar.
2. Delete **DataHawk.app** from your Applications folder.
3. Remove the login item in **System Settings → General → Login Items** if you had enabled it.

## Build from source

Requires Xcode Command Line Tools (`xcode-select --install`). No third-party dependencies.

```bash
# Clone the repo
git clone https://github.com/valeriansaliou/datahawk.git
cd datahawk

# Build DataHawk.app in the project root
make app

# Build and launch immediately (kills any running instance first, used for development)
make app-dev

# Clean all build artefacts
make clean
```

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

## Available shortcuts

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
