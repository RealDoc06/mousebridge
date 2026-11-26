import AppKit
import BridgeCore
import Observation

/// The displays as they physically sit on the desk, left to right at real scale.
/// Physical tops are saved per display (see `persistentKey`), so an arrangement survives reconnects.
/// Displays stacked directly above or below the row are arranged in macOS only. Displays that report no physical
/// size, mirrors, and anything stacked further out are left out and left to macOS.
@MainActor @Observable
final class Desk {
    struct Screen: Identifiable {
        let id: CGDirectDisplayID
        let key: String
        var display: Display
    }

    /// A display directly above or below the row.
    struct Stacked {
        let screen: Screen
        /// Index in `row` of the display it's stacked on.
        let host: Int
    }

    /// Left to right, as macOS arranges them.
    private(set) var screens: [Screen] = []
    /// The displays that sit side by side in macOS, left to right, each touching the next with rows in common:
    /// the longest such chain, then the one sharing the most edge, then the main display's. A display stacked above or below them is in
    /// `stacked` instead.
    var row: [Screen] { screens.filter { rowIDs.contains($0.id) } }
    /// Displays directly above or below one in the row. The cursor bridge leaves them alone, since macOS crosses
    /// vertical edges fine.
    var stacked: [Stacked] {
        let row = row
        return screens.compactMap { s in
            stackedHosts[s.id].flatMap { h in row.firstIndex { $0.id == h } }.map { Stacked(screen: s, host: $0) }
        }
    }
    /// True when the row and the displays stacked on it are every active display, so reordering can't overlap one
    /// left out.
    private(set) var canReorder = false
    /// Shows lines where display edges line up, and snaps drags to them.
    var guides = UserDefaults.standard.bool(forKey: "guides") {
        didSet { UserDefaults.standard.set(guides, forKey: "guides") }
    }
    /// Called with the row's displays whenever their geometry or arrangement changes.
    @ObservationIgnored var onChange: (([Display]) -> Void)?

    private static let topsKey = "physicalTops"

    private var rowIDs: Set<CGDirectDisplayID> = []
    /// The row display each stacked display touches most, by display ID.
    private var stackedHosts: [CGDirectDisplayID: CGDirectDisplayID] = [:]

    /// Re-reads geometry and physical sizes. Call after the display setup changes.
    /// Displays never arranged here start lined up by the old Top/Center/Bottom setting.
    func reload() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.topsKey) as? [String: Double] ?? [:]
        let preset = Alignment(rawValue: UserDefaults.standard.string(forKey: "alignment") ?? "") ?? .bottom
        let active = activeDisplays()
        // A mirror shows another display's content, so only the display it mirrors takes a place.
        let ids = active.filter { CGDisplayScreenSize($0).width > 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        // Identical monitors that report no serial would share a key, so those also key by the port they're on.
        var screens = ids.map { id in
            Screen(
                id: id,
                key: CGDisplaySerialNumber(id) == 0 ? "\(persistentKey(id))-\(CGDisplayUnitNumber(id))" : persistentKey(id),
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
        // Main's chain first, so it wins full ties: `max` keeps the first of equals.
        let starts = screens.sorted { a, b in a.id == CGMainDisplayID() && b.id != CGMainDisplayID() }
        let chains = starts.map { start in
            let ids = Self.row(from: start, in: screens)
            let chain = screens.filter { ids.contains($0.id) } // left to right, each beside the next
            return (ids: ids, edge: zip(chain, chain.dropFirst()).map { Self.shared($0.display.frame, $1.display.frame) }.reduce(0, +))
        }
        rowIDs = chains.max { ($0.ids.count, $0.edge) < ($1.ids.count, $1.edge) }?.ids ?? []
        let row = screens.filter { rowIDs.contains($0.id) }
        stackedHosts = [:]
        for s in screens where !rowIDs.contains(s.id) {
            stackedHosts[s.id] = Arrangement.host(of: s.display.frame, among: row.map(\.display.frame)).map { row[$0].id }
        }
        canReorder = rowIDs.count + stackedHosts.count == active.count
        onChange?(row.map(\.display))
    }

    /// `start` and the displays chained beside it, each step taking the neighbor that shares the most rows.
    private static func row(from start: Screen, in screens: [Screen]) -> Set<CGDirectDisplayID> {
        var ids: Set<CGDirectDisplayID> = [start.id]
        for leftward in [true, false] {
            var current = start.display.frame
            while let next = screens.filter({ !ids.contains($0.id) && (leftward
                ? Layout.borders($0.display.frame, current) : Layout.borders(current, $0.display.frame)) })
                .max(by: { shared($0.display.frame, current) < shared($1.display.frame, current) }) {
                ids.insert(next.id)
                current = next.display.frame
            }
        }
        return ids
    }

    /// Rows two side-by-side frames have in common.
    private static func shared(_ a: CGRect, _ b: CGRect) -> CGFloat { min(a.maxY, b.maxY) - max(a.minY, b.minY) }

    /// Moves a display's physical top and saves the row's arrangement. Tops stay on one axis across saves, so
    /// displays disconnected meanwhile keep their place relative to the rest.
    func setTop(_ top: CGFloat, of id: CGDirectDisplayID) {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return }
        screens[i].display.topMM = top
        var saved = UserDefaults.standard.dictionary(forKey: Self.topsKey) as? [String: Double] ?? [:]
        for s in row { saved[s.key] = s.display.topMM }
        UserDefaults.standard.set(saved, forKey: Self.topsKey)
        onChange?(row.map(\.display))
    }

    /// Puts the displays side by side in macOS's arrangement in `order`, left to right, keeping each one's
    /// vertical position. Stacked displays move with the display they sit on.
    func reorder(_ order: [CGDirectDisplayID]) {
        guard canReorder else { return }
        let frames = order.map(CGDisplayBounds)
        var x: CGFloat = 0
        let xs = frames.map { f in defer { x += f.width }; return x }
        var origins = Dictionary(uniqueKeysWithValues: order.indices.map { (order[$0], CGPoint(x: xs[$0], y: frames[$0].minY)) })
        for (id, host) in stackedHosts {
            guard let hostOrigin = origins[host] else { continue }
            let f = CGDisplayBounds(id)
            origins[id] = CGPoint(x: hostOrigin.x + f.minX - CGDisplayBounds(host).minX, y: f.minY)
        }
        configure(origins)
    }

    /// Moves a stacked display in macOS's arrangement to `origin` (global points), e.g. along or onto another
    /// display's top or bottom edge.
    func move(_ id: CGDirectDisplayID, to origin: CGPoint) {
        guard stackedHosts[id] != nil else { return }
        configure([id: origin])
    }

    /// Applies display origins in one configuration, shifted so the main display stays at (0, 0) as Quartz requires:
    /// moving the main display moves everything else the other way. Quartz may nudge displays to keep them
    /// touching, so the real frames are read back right away.
    private func configure(_ origins: [CGDirectDisplayID: CGPoint]) {
        var origins = origins
        if let shift = origins[CGMainDisplayID()], shift != .zero {
            for id in activeDisplays() where origins[id] == nil && CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay {
                origins[id] = CGDisplayBounds(id).origin
            }
            origins = origins.mapValues { CGPoint(x: $0.x - shift.x, y: $0.y - shift.y) }
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for (id, o) in origins where CGConfigureDisplayOrigin(config, id, Int32(o.x), Int32(o.y)) != .success {
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
