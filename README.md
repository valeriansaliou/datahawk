# DataHawk

**DataHawk** is a lightweight macOS menu bar app that monitors your 5G mobile hotspot in real time. It sits quietly in the status bar and displays live cellular metrics — signal strength, data usage, battery level, and more — fetched directly from your router's admin API.

Supported hotspots:

- **NETGEAR**
  - **Nighthawk** (M3, M6, M6 Pro).

---

## Screenshots

<img width="1616" height="888" alt="datahawk-screenshot-1" src="https://github.com/user-attachments/assets/07978787-c3e6-49d0-ab6a-0268f4e76c67" />

<img width="1800" height="993" alt="datahawk-screenshot-2" src="https://github.com/user-attachments/assets/d32b4fc3-3375-4459-84fa-e234c4f1cea8" />

---

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

---

## Building

```bash
# Clone the repo
git clone https://github.com/valeriansaliou/datahawk.git
cd datahawk

# Build the app bundle
make

# Build and launch immediately
make all-dev

# Clean build artefacts
make clean
```

The build produces `.build/DataHawk.app`. You can move it to `/Applications` like any other app.

### Code signing (optional)

Pass your signing identity to skip the interactive prompt:

```bash
make SIGN_ID="Developer ID Application: Your Name (XXXXXXXXXX)"
```

Leave it empty to build without signing (works fine for local use). You can also add this to a `local.env` file (prefixed with `export`).

---

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

---

## Usage

| Action | Result |
|---|---|
| **Click** the icon | Open / close the metrics popover |
| **Click ↻** in the popover | Force a refresh of metrics |
| **Option-click ↻** | Force full refresh of metrics (re-authenticates) |
| **Option-click** the icon | Show WiFi QR code share window |
| **Click QR button** | Show WiFi QR code share window |
| **Click Settings** | Open the hotspot and options configuration window |

---

## License

MIT — see [LICENSE](LICENSE).
