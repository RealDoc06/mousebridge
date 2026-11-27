import AppKit
import Observation

/// One connected display and the controls it actually supports.
/// Brightness goes over DDC when the display answers, otherwise through gamma dimming, or a `Shade` on virtual
/// displays that gamma doesn't reach. A DDC display also gets macOS's own brightness slider (`NativeBrightness`).
@MainActor @Observable
final class Monitor: Identifiable {
    let id: CGDirectDisplayID
    /// Name the display reports in its EDID.
    let defaultName: String
    /// Name chosen in the menu, saved per physical display. Empty shows `defaultName`.
    var customName: String {
        didSet { UserDefaults.standard.set(customName, forKey: nameKey) }
    }
    var name: String { customName.isEmpty ? defaultName : customName }
    let hdrSupported: Bool
    let dimming: Dimming
    private(set) var brightness: Double
    /// nil when the display reports no volume control (no speakers).
    private(set) var volume: Double?
    private(set) var hdr: Bool

    enum Dimming { case ddc, gamma, shade }

    @ObservationIgnored private let ddc: DDC?
    /// Where macOS's brightness slider for the display reads and sets the level, when it has one.
    @ObservationIgnored let native: BrightnessDevice?
    @ObservationIgnored private let maxBrightness: UInt16
    @ObservationIgnored private let maxVolume: UInt16
    @ObservationIgnored private let nameKey: String

    /// Software-dimmed displays never go fully black.
    private static let minSoftwareBrightness = 0.1

    fileprivate init(_ probe: Probe, softwareBrightness: Double?, native: BrightnessDevice?) {
        id = probe.id
        self.native = native
        defaultName = NSScreen.screens.first { $0.displayID == probe.id }?.localizedName ?? "Display \(probe.id)"
        nameKey = "name.\(persistentKey(probe.id))"
        customName = UserDefaults.standard.string(forKey: nameKey) ?? ""
        hdrSupported = HDR.isSupported(probe.id)
        hdr = HDR.isEnabled(probe.id)
        let ddcBrightness = probe.brightness
        ddc = ddcBrightness == nil ? nil : probe.ddc
        maxBrightness = ddcBrightness?.max ?? 100
        maxVolume = probe.volume?.max ?? 100
        volume = probe.volume.map { Double($0.value) / Double(max($0.max, 1)) }
        // A mirror has the bounds of the display it mirrors, which a shade would cover instead.
        let mirror = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
        dimming = ddcBrightness != nil ? .ddc : probe.virtual && !mirror ? .shade : .gamma
        if let ddcBrightness {
            brightness = min(Double(ddcBrightness.value) / Double(max(ddcBrightness.max, 1)), 1)
        } else {
            brightness = softwareBrightness ?? 1
            dim()
        }
    }

    func setBrightness(_ value: Double) {
        if ddc != nil {
            brightness = min(max(value, 0), 1)
            // Set through macOS when the display has its slider, so the slider follows. The level comes back from
            // `native` to `takeSystemBrightness`, which sends it to the display.
            if native != nil, SystemBrightness.set(id, brightness) { return }
            sendBrightness()
        } else {
            brightness = min(max(value, Self.minSoftwareBrightness), 1)
            dim()
        }
    }

    /// Takes a level macOS set with the display's own slider (Control Center, System Settings, `setBrightness`).
    func takeSystemBrightness(_ level: Double) {
        brightness = level
        sendBrightness()
    }

    private func sendBrightness() {
        ddc?.set(.brightness, UInt16((brightness * Double(maxBrightness)).rounded()))
    }

    /// Applies `brightness` in software.
    private func dim() {
        if dimming == .shade { Shade.dim(id, to: brightness) } else { Gamma.dim(id, to: brightness) }
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
    /// What macOS reads as the display's EDID, for displays that answer DDC.
    let edid: [UInt8]?
    /// No framebuffer behind it, so gamma can't dim it.
    let virtual: Bool
}

/// All connected displays. Reloads on display changes and handles the brightness keys.
@MainActor @Observable
final class Monitors {
    private(set) var all: [Monitor] = []
    /// Counts reloads, so one superseded while it waits or probes is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let native = NativeBrightness()

    /// Re-probes every display after `settle`. DDC reads take tens of milliseconds each, so they run in the
    /// background. Right after a display change monitors often don't answer DDC yet and macOS resets gamma a moment
    /// later, so changes settle first. That also folds a burst of change notifications into one probe.
    func reload(settle: Duration = .zero) async {
        generation += 1
        let current = generation
        try? await Task.sleep(for: settle)
        guard current == generation else { return }
        let probes = await Task.detached {
            let channels = DDC.discover(), reachable = Gamma.reachable()
            return activeDisplays().map { id in
                let ddc = channels[id]
                let brightness = ddc?.get(.brightness)
                return Probe(
                    id: id, ddc: ddc, brightness: brightness, volume: brightness == nil ? nil : ddc?.get(.volume),
                    edid: brightness == nil ? nil : ddc?.edid(), virtual: !reachable.contains(id)
                )
            }
        }.value
        guard current == generation else { return }
        // Gamma resets on display changes, so software-dimmed levels are carried over and reapplied.
        let previous = Dictionary(all.filter { $0.dimming != .ddc }.map { ($0.id, $0.brightness) }, uniquingKeysWith: { a, _ in a })
        let devices = native.link(probes.compactMap { p in
            guard let ddc = p.ddc, let edid = p.edid, let b = p.brightness else { return nil }
            return .init(id: p.id, ddc: ddc, edid: edid, level: min(Double(b.value) / Double(max(b.max, 1)), 1))
        }) { [weak self] id, level in
            self?.all.first { $0.id == id }?.takeSystemBrightness(level)
        }
        all = probes.map { Monitor($0, softwareBrightness: previous[$0.id], native: devices[$0.id]) }
        Shade.keep(all.filter { $0.dimming == .shade }.map(\.id))
        for device in devices.values where !device.seeded {
            device.seeded = true
            seed(device)
        }
    }

    /// Gives macOS's slider the display's level once per device, since macOS keeps its own last level rather than
    /// reading the device's. Waits (up to 3 s) for macOS to link a device that was just created, then sets the level
    /// of the monitor that has it now; if that fails, the next reload tries again. A device a reload drops meanwhile
    /// is let go.
    private func seed(_ device: BrightnessDevice) {
        Task { [weak self, weak device] in
            for _ in 0..<30 {
                guard let id = device?.display, !SystemBrightness.isLinked(id) else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let device else { return }
            guard let monitor = self?.all.first(where: { $0.native === device }),
                  SystemBrightness.set(monitor.id, monitor.brightness) else { device.seeded = false; return }
        }
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
