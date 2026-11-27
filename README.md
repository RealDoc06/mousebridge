<div align="center">

# MouseBridge

**Mixed monitors, one desk.**<br>
Your cursor crosses between displays at the height it physically is, and every display gets brightness, volume and HDR in the menu bar.

[![Latest release](https://img.shields.io/github/v/release/RealDoc06/mousebridge?style=flat-square&color=0a84ff&label=release)](https://github.com/RealDoc06/mousebridge/releases/latest) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000?style=flat-square&logo=apple&logoColor=white) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-000?style=flat-square)

[**Download**](https://github.com/RealDoc06/mousebridge/releases/latest)

<br>

<img src="docs/crossing.svg" alt="macOS moves the cursor by pixels, so it jumps between a 24.5 inch 1080p and a 27 inch 1440p display. MouseBridge moves it by physical height." width="880">

</div>

## Why

macOS moves the cursor between displays by points. Put a 27" 1440p next to a 24.5" 1080p and the cursor jumps up or down every time it crosses, and part of the taller edge becomes a wall. MouseBridge reads each display's real size from its EDID and maps crossings to the same physical height, so the cursor goes straight across like the displays were one.

## Features

<img src="docs/menu.png" alt="The MouseBridge menu: arrangement, linked brightness, per display brightness, volume and HDR, settings" width="320" align="right">

**Cursor bridge.** Left and right crossings land at the same physical height. The extra strip of a taller display clamps to the nearest row, so the whole edge crosses. A display stacked above or below the row (an iPad under a monitor) is entered only where it physically sits.

**Real-scale arrangement.** The menu draws your displays at their true size. Drag one to match the desk, nudge it a pixel with the arrow keys, or drag past a neighbor to reorder it in macOS.

**Alignment guides.** The ruler button draws guides on the real displays at every other display's edges and center, each in its own color, so you can line them up with the bezels.

**Brightness that just works.** DDC/CI when the display answers, software dimming when it doesn't (common behind USB-C to HDMI adapters), an overlay for Sidecar. The brightness keys adjust the display under the cursor, Option+Shift for fine steps.

**Native macOS slider.** Optionally, DDC displays get the same brightness slider in Control Center and System Settings that Apple displays have.

**Linked displays.** Link displays to change their brightness together, from any member's slider, keys, or Control Center.

**HDR and volume.** Toggle HDR where supported, set volume on displays with speakers.

**Auto updates.** Signed, notarized, and updated through Sparkle.

<br clear="right">

## Line them up

Turn on the guides and drag until the lines meet the bezels. Each display marks the other's edges and center, at physical scale.

<img src="docs/guides.png" alt="Two displays side by side with MouseBridge alignment guides drawn across both screens" width="880">

## Install

1. Download the latest zip from [Releases](https://github.com/RealDoc06/mousebridge/releases/latest), unzip it, and move **MouseBridge** to Applications.
2. Open it and grant **Accessibility** when asked. It runs the cursor bridge and the brightness keys.
3. Open the menu bar icon and drag your displays to match the desk.

Requires macOS 14 or later and Apple Silicon.

## Good to know

- **macOS brightness slider** (Settings) publishes a virtual brightness device and gives the display a virtual EDID. The display goes black for a moment while macOS picks it up, again after a reboot or reconnect. Displays whose EDID already has a ContainerID, and identical displays with no serial number, keep MouseBridge's own slider and keys.
- **Sidecar and other virtual displays** ignore gamma, so they're dimmed with a click-through overlay. An iPad's own backlight stays set on the iPad.
- **Scope.** The bridge handles side-by-side displays and displays stacked on them. Other vertical crossings, like inside a 2×2 grid, are left to macOS.

## Develop

```sh
swift test               # cursor mapping tests
scripts/build-app.sh     # signed build/MouseBridge.app
scripts/release.sh       # next patch (v0.4.0 -> 0.4.1): tag, build, notarize, sign appcast, publish GitHub release
```

Releases need the Sparkle EdDSA key at `~/.config/mousebridge/sparkle_ed25519` (`SPARKLE_KEY`) and a notarytool keychain profile named `mousebridge` (`NOTARY_PROFILE`). The Control Center slider needs the HID Virtual Device entitlement, which `signing/MouseBridge.provisionprofile` (Developer ID, team 2JT7745BQ2) grants.
