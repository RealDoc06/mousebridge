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

    /// True when the displays sit side by side in macOS, each touching the next with rows in common.
    /// Only then does the arrangement match the desk; stacked displays are left to macOS.
    private(set) var isRow = false
    /// True when the displays form a row and every active display is in it, so reordering can't overlap one left out.
    private(set) var canReorder = false

    /// Re-reads geometry and physical sizes. Call after the display setup changes.
    /// Displays never arranged here start lined up by the old Top/Center/Bottom setting.
    func reload() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.topsKey) as? [String: Double] ?? [:]
        let preset = Alignment(rawValue: UserDefaults.standard.string(forKey: "alignment") ?? "") ?? .bottom
        let active = activeDisplays()
        // A mirror shows another display's content, so only the display it mirrors takes a place.
        let ids = active.filter { CGDisplayScreenSize($0).width > 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        // Identical monitors that report no serial share a key, so those also key by the port they're on.
        let keys = ids.map(persistentKey)
        var screens = zip(ids, keys).map { id, key in
            Screen(
                id: id,
                key: keys.filter { $0 == key }.count > 1 ? "\(key)-\(CGDisplayUnitNumber(id))" : key,
                display: Display(frame: CGDisplayBounds(id), widthMM: CGDisplayScreenSize(id).width)
            )
        }
        .sorted { $0.display.frame.minX < $1.display.frame.minX }
        // Line new displays up with the tallest arranged one, or with the tallest overall before any arranging.
        let arranged = screens.filter { saved[$0.key] != nil }
        if let reference = (arranged.isEmpty ? screens : arranged).max(by: { $0.display.heightMM < $1.display.heightMM }) {
            let anchor = saved[reference.key].map { CGFloat($0) } ?? 0
            for i in screens.indices {
                let d = screens[i].display
                screens[i].display.topMM = saved[screens[i].key].map { CGFloat($0) }
                    ?? anchor + preset.top(heightMM: d.heightMM, tallestMM: reference.display.heightMM)
            }
        }
        self.screens = screens
        isRow = zip(screens, screens.dropFirst()).allSatisfy { a, b in
            let a = a.display.frame, b = b.display.frame
            return abs(b.minX - a.maxX) < 1 && a.minY < b.maxY && b.minY < a.maxY
        }
        canReorder = isRow && screens.count == active.count
        onChange?(screens.map(\.display))
    }

    /// Moves a display's physical top and saves the arrangement. Tops stay on one axis across saves, so
    /// displays disconnected meanwhile keep their place relative to the rest.
    func setTop(_ top: CGFloat, of id: CGDirectDisplayID) {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return }
        screens[i].display.topMM = top
        var saved = UserDefaults.standard.dictionary(forKey: Self.topsKey) as? [String: Double] ?? [:]
        for s in screens { saved[s.key] = s.display.topMM }
        UserDefaults.standard.set(saved, forKey: Self.topsKey)
        onChange?(screens.map(\.display))
    }

    /// Puts the displays side by side in macOS's arrangement in `order`, left to right, keeping each one's
    /// vertical position and the main display at the origin. Quartz may nudge displays to keep them touching,
    /// so the real frames are read back right away.
    func reorder(_ order: [CGDirectDisplayID]) {
        guard canReorder, let main = order.firstIndex(of: CGMainDisplayID()) else { return }
        let frames = order.map(CGDisplayBounds)
        var x: CGFloat = 0
        let xs = frames.map { f in defer { x += f.width }; return x }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for (i, id) in order.enumerated()
        where CGConfigureDisplayOrigin(config, id, Int32(xs[i] - xs[main]), Int32(frames[i].minY)) != .success {
            CGCancelDisplayConfiguration(config)
            return
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else { return }
        reload()
    }
}

/// Identifies a physical display across reboots and reconnects, where display IDs can change.
func persistentKey(_ id: CGDirectDisplayID) -> String {
    "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
}
