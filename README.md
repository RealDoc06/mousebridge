# MouseBridge

A macOS menu bar app for mixed external displays.

- **Cursor bridge.** macOS moves the cursor between displays by points, so a 27" 1440p next to a 24.5" 1080p makes it jump in height and leaves part of the taller edge dead. MouseBridge remaps left/right crossings to the same physical height using each display's EDID size and where it sits on the desk. The extra strip of a taller display clamps to the nearest row, so the whole edge crosses. Crossings to a display stacked above or below the row (an iPad under a monitor) keep the cursor's physical position along the desk: it goes through only where that display physically sits, wherever macOS has it.
- **Arrangement.** The menu shows the displays at real scale. Drag one up or down to match the desk (the arrows nudge the selected one a pixel), or past a neighbor to reorder it in macOS. The ruler button draws guides on the real displays at the other displays' edges, each display's in its own color (marked on its tile), so you can check them against the bezels, and snaps drags to aligned edges. Displays stacked above or below the row show at real scale too; drag one to where it physically sits along the desk, under another display or to the other side, or past either end of the row to put it beside the end display. It and the row displays in front of it show each other's left edge, center and right edge as vertical guides, so you can line it up with the bezels. Drag an end display past the top or bottom to stack it on its neighbor instead.
- **Brightness.** DDC/CI when the display answers, gamma dimming otherwise (common behind USB-C to HDMI adapters). Virtual displays such as Sidecar ignore gamma, so they get a click-through dimming overlay; an iPad's own backlight stays set on the iPad. Keyboard brightness keys adjust the display under the cursor; Option+Shift for fine steps.
- **HDR toggle** for displays that support it.
- **Volume** only for displays that report speakers over DDC.
- **Auto updates** through Sparkle, from this repo's GitHub releases.

Requires Accessibility permission (cursor and brightness keys) and Apple Silicon (DDC).

## Develop

```sh
swift test                       # cursor mapping tests
scripts/build-app.sh             # signed build/MouseBridge.app
scripts/release.sh 0.2.0         # tag, build, sign appcast, publish GitHub release
```

Releases need the Sparkle EdDSA key at `~/.config/mousebridge/sparkle_ed25519` (`SPARKLE_KEY`) and a notarytool keychain profile named `mousebridge` (`NOTARY_PROFILE`).

Scope: the cursor bridge handles side-by-side displays and displays stacked on them. Other vertical crossings, like within a 2×2 grid, are left to macOS.
