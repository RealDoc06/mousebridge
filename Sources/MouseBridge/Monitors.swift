import AppKit
import Observation

/// One connected display and the controls it actually supports.
/// Brightness goes over DDC when the display answers, otherwise through gamma dimming.
@MainActor @Observable
final class Monitor: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let hdrSupported: Bool
    private(set) var brightness: Double
    /// nil when the display reports no volume control (no speakers).
    private(set) var volume: Double?
    private(set) var hdr: Bool

    @ObservationIgnored private let ddc: DDC?
    @ObservationIgnored private let maxBrightness: UInt16
    @ObservationIgnored private let maxVolume: UInt16

    /// Software-dimmed displays never go fully black.
    private static let minSoftwareBrightness = 0.1

    fileprivate init(_ probe: Probe, softwareBrightness: Double?) {
        id = probe.id
        name = NSScreen.screens.first { $0.displayID == probe.id }?.localizedName ?? "Display \(probe.id)"
        hdrSupported = HDR.isSupported(probe.id)
        hdr = HDR.isEnabled(probe.id)
        let ddcBrightness = probe.brightness
        ddc = ddcBrightness == nil ? nil : probe.ddc
        maxBrightness = ddcBrightness?.max ?? 100
        maxVolume = probe.volume?.max ?? 100
        volume = probe.volume.map { Double($0.value) / Double(max($0.max, 1)) }
        if let ddcBrightness {
            brightness = Double(ddcBrightness.value) / Double(max(ddcBrightness.max, 1))
        } else {
            brightness = softwareBrightness ?? 1
            Gamma.dim(id, to: brightness)
        }
    }

    var usesDDC: Bool { ddc != nil }

    func setBrightness(_ value: Double) {
        if let ddc {
            brightness = min(max(value, 0), 1)
            ddc.set(.brightness, UInt16((brightness * Double(maxBrightness)).rounded()))
        } else {
            brightness = min(max(value, Self.minSoftwareBrightness), 1)
            Gamma.dim(id, to: brightness)
        }
    }

    func setVolume(_ value: Double) {
        guard let ddc, volume != nil else { return }
        volume = min(max(value, 0), 1)
        ddc.set(.volume, UInt16((volume! * Double(maxVolume)).rounded()))
    }

    func setHDR(_ on: Bool) {
        HDR.setEnabled(id, on)
        hdr = HDR.isEnabled(id)
    }

    /// HDR can also be switched in System Settings, so re-read it when the menu opens.
    func refreshHDR() { hdr = HDR.isEnabled(id) }
}

/// What a display answered over DDC, gathered off the main thread.
private struct Probe: Sendable {
    let id: CGDirectDisplayID
    let ddc: DDC?
    let brightness: (value: UInt16, max: UInt16)?
    let volume: (value: UInt16, max: UInt16)?
}

/// All connected displays. Reloads on display changes and handles the brightness keys.
@MainActor @Observable
final class Monitors {
    private(set) var all: [Monitor] = []

    /// Re-probes every display. DDC reads take tens of milliseconds each, so they run in the background.
    func reload() async {
        let probes = await Task.detached {
            let channels = DDC.discover()
            return activeDisplays().map { id in
                let ddc = channels[id]
                let brightness = ddc?.get(.brightness)
                return Probe(id: id, ddc: ddc, brightness: brightness, volume: brightness == nil ? nil : ddc?.get(.volume))
            }
        }.value
        // Gamma resets on display changes, so software-dimmed levels are carried over and reapplied.
        let previous = Dictionary(all.filter { !$0.usesDDC }.map { ($0.id, $0.brightness) }, uniquingKeysWith: { a, _ in a })
        all = probes.map { Monitor($0, softwareBrightness: previous[$0.id]) }
    }

    /// Brightness key: steps the display under the cursor by 1/16, or 1/64 with Option+Shift.
    func step(up: Bool, fine: Bool) {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard let monitor = all.first(where: { CGDisplayBounds($0.id).contains(cursor) }) ?? all.first else { return }
        let step = (fine ? 1.0 / 64 : 1.0 / 16) * (up ? 1 : -1)
        monitor.setBrightness(((monitor.brightness + step) * 64).rounded() / 64)
        HUD.show(monitor.brightness, on: monitor.id)
    }

    func refreshHDR() { all.forEach { $0.refreshHDR() } }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
