import AppKit
import BridgeCore
import Observation

/// The displays as they physically sit on the desk, left to right at real scale.
/// Physical tops are saved per display (see `persistentKey`), so an arrangement survives reconnects.
/// Displays that report no physical size, and mirrors, are left out and left to macOS.
@MainActor @Observable
final class Desk {
    struct Screen: Identifiable {
        let id: CGDirectDisplayID
        let key: String
        var display: Display
    }

    /// Left to right, as macOS arranges them.
    private(set) var screens: [Screen] = []
    /// Shows lines where display edges line up, and snaps drags to them.
    var guides = UserDefaults.standard.bool(forKey: "guides") {
        didSet { UserDefaults.standard.set(guides, forKey: "guides") }
    }
    /// Called with the displays whenever their geometry or arrangement changes.
    @ObservationIgnored var onChange: (([Display]) -> Void)?

    private static let topsKey = "physicalTops"

    /// True when every active display is on the desk, so reordering can't overlap one left out.
    private(set) var canReorder = false

    /// Re-reads geometry and physical sizes. Call after the display setup changes.
    /// Displays never arranged here start lined up with the tallest by the old Top/Center/Bottom setting.
    func reload() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.topsKey) as? [String: Double] ?? [:]
        let preset = Alignment(rawValue: UserDefaults.standard.string(forKey: "alignment") ?? "") ?? .bottom
        let active = activeDisplays()
        var screens = active.compactMap { id -> Screen? in
            let mm = CGDisplayScreenSize(id)
            // A mirror shows another display's content, so only the display it mirrors takes a place.
            guard mm.width > 0, CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            return Screen(id: id, key: persistentKey(id), display: Display(frame: CGDisplayBounds(id), widthMM: mm.width))
        }
        .sorted { $0.display.frame.minX < $1.display.frame.minX }
        if let tallest = screens.max(by: { $0.display.heightMM < $1.display.heightMM }) {
            let anchor = saved[tallest.key].map { CGFloat($0) } ?? 0
            for i in screens.indices {
                let d = screens[i].display
                screens[i].display.topMM = saved[screens[i].key].map { CGFloat($0) }
                    ?? anchor + preset.top(heightMM: d.heightMM, tallestMM: tallest.display.heightMM)
            }
        }
        self.screens = screens
        canReorder = screens.count == active.count
        onChange?(screens.map(\.display))
    }

    /// Moves a display's physical top and saves the whole arrangement, shifted so the highest top is 0.
    func setTop(_ top: CGFloat, of id: CGDirectDisplayID) {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return }
        screens[i].display.topMM = top
        let lowest = screens.map(\.display.topMM).min() ?? 0
        for j in screens.indices { screens[j].display.topMM -= lowest }
        var saved = UserDefaults.standard.dictionary(forKey: Self.topsKey) as? [String: Double] ?? [:]
        for s in screens { saved[s.key] = s.display.topMM }
        UserDefaults.standard.set(saved, forKey: Self.topsKey)
        onChange?(screens.map(\.display))
    }

    /// Puts the displays side by side in macOS's arrangement in `order`, left to right, keeping each one's
    /// vertical position and the main display at the origin. macOS then posts a screen change, which should reload.
    func reorder(_ order: [CGDirectDisplayID]) {
        guard canReorder, order.contains(CGMainDisplayID()) else { return }
        let frames = order.map(CGDisplayBounds)
        var x: CGFloat = 0
        let xs = frames.map { f in defer { x += f.width }; return x }
        let shift = xs[order.firstIndex(of: CGMainDisplayID())!]
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for (i, id) in order.enumerated() {
            CGConfigureDisplayOrigin(config, id, Int32(xs[i] - shift), Int32(frames[i].minY))
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else { return }
        // Show the new order now; the reload that follows brings the new frames.
        screens = order.compactMap { id in screens.first { $0.id == id } }
    }
}

/// Identifies a physical display across reboots and reconnects, where display IDs can change.
func persistentKey(_ id: CGDirectDisplayID) -> String {
    "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
}
