import AppKit
import BridgeCore
import SwiftUI

/// Lines drawn over the real displays while arranging with guides on. Each display shows the top, center and bottom
/// of the others at their physical height (`Arrangement.guides(on:in:)`), in the color of the display they come
/// from (`color(_:)`, also marked on its tile), so a line that runs level into that display's actual bezel edge
/// means the arrangement matches the desk. Clicks pass through.
@MainActor
enum GuideOverlay {
    private static var panels: [CGDirectDisplayID: NSPanel] = [:]

    /// The guide color of the display at `index` in the row, left to right: blue, yellow, green, then on.
    static func color(_ index: Int) -> NSColor {
        let colors: [NSColor] = [.systemBlue, .systemYellow, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal]
        return colors[index % colors.count]
    }

    /// Shows the lines for `displays` (as arranged, with any drag in progress), indexed like `ids`.
    /// Runs on every drag step, so it only redraws lines and touches panels that changed.
    static func show(_ ids: [CGDirectDisplayID], _ displays: [Display]) {
        for (id, panel) in panels where !ids.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        // Panels are placed from Quartz's frames, which update before AppKit's screen list after a reorder.
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        for (i, id) in ids.enumerated() {
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            let f = displays[i].frame
            let frame = CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            (panel.contentView as? GuideLinesView)?.guides = Arrangement.guides(on: i, in: displays)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    static func hide() { panels.values.forEach { $0.orderOut(nil) } }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Over a display dimmed by `Shade`, under the menu's own popup.
        panel.level = Shade.level + 1
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = GuideLinesView()
        return panel
    }
}

/// Full-width lines at the guides' rows, in points from the top, in their source display's color, snapped to
/// device pixels and kept inside the edges.
private final class GuideLinesView: NSView {
    var guides: [Arrangement.Guide] = [] {
        didSet { if guides != oldValue { needsDisplay = true } }
    }
    private static let thickness: CGFloat = 2

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for guide in guides {
            GuideOverlay.color(guide.source).setFill()
            let y = min(max(guide.row - Self.thickness / 2, 0), bounds.height - Self.thickness)
            backingAlignedRect(CGRect(x: 0, y: y, width: bounds.width, height: Self.thickness), options: .alignAllEdgesNearest).fill()
        }
    }
}

/// Calls `action` with whether the window holding this view is on screen: once when attached, then as it
/// opens and closes. A MenuBarExtra popup keeps its views alive while closed, so `onAppear` and `onDisappear`
/// miss that.
struct OnWindowVisibility: NSViewRepresentable {
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ view: VisibilityView, context: Context) { view.action = action }

    final class VisibilityView: NSView {
        var action: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        /// Also runs with no window when the view leaves it, before it goes away, which drops the observer.
        override func viewDidMoveToWindow() {
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { DispatchQueue.main.async { [action] in action?(false) }; return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.action?(self?.window?.occlusionState.contains(.visible) ?? false) }
            }
            // Reported a turn later, since SwiftUI state can't change while the view is being attached.
            DispatchQueue.main.async { [weak self] in self?.action?(self?.window?.occlusionState.contains(.visible) ?? false) }
        }
    }
}
