# MouseBridge

A macOS menu bar app for mixed external displays.

- **Cursor bridge.** macOS moves the cursor between displays by points, so a 27" 1440p next to a 24.5" 1080p makes it jump in height and leaves part of the taller edge dead. MouseBridge remaps left/right crossings to the same physical height using each display's EDID size and where it sits on the desk. The extra strip of a taller display clamps to the nearest row, so the whole edge crosses.
- **Arrangement.** The menu shows the displays at real scale. Drag one up or down to match the desk, or past a neighbor to reorder it in macOS. The ruler button shows yellow guides where edges line up and snaps drags to them.
- **Brightness.** DDC/CI when the display answers, gamma dimming otherwise (common behind USB-C to HDMI adapters). Keyboard brightness keys adjust the display under the cursor; Option+Shift for fine steps.
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

Scope: side-by-side displays. Vertical crossings are left to macOS.
