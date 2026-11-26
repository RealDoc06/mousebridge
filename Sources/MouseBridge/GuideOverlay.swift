import AppKit
import BridgeCore
import SwiftUI

/// Lines drawn over the real displays while arranging with guides on, in the color of the display they come from
/// (`color(_:)`, also marked on its tile). Each row display shows the top, center and bottom of the others at their
/// physical height (`Arrangement.guides(on:in:)`), so a line that runs level into that display's actual bezel edge
/// means the arrangement matches the desk. A stacked display and each display it touches show each other's left
/// edge, center and right edge as columns (`Arrangement.columns(on:of:)`), the same check across a top or bottom edge. Clicks pass
/// through.
@MainActor
enum GuideOverlay {
    /// A display stacked above or below the row: its frame, the frame it's being dragged to (the same when it isn't),
    /// and the indices in the row of the displays whose edge it touches there.
    struct Stacked: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let placed: CGRect
        let touching: [Int]
    }

    private static var panels: [CGDirectDisplayID: NSPanel] = [:]

    /// The guide color of the display at `index`, counting the row left to right and then the stacked displays:
    /// blue, yellow, green, then on.
    static func color(_ index: Int) -> NSColor {
        let colors: [NSColor] = [.systemBlue, .systemYellow, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal]
        return colors[index % colors.count]
    }

    /// Shows the lines for the row `displays` (as arranged, with any drag in progress), indexed like `ids`, and for
    /// the `stacked` displays. Runs on every drag step, so it only redraws lines and touches panels that changed.
    static func show(_ ids: [CGDirectDisplayID], _ displays: [Display], stacked: [Stacked]) {
        let shown = ids + stacked.map(\.id)
        for (id, panel) in panels where !shown.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for (i, id) in ids.enumerated() {
            let rows = Arrangement.guides(on: i, in: displays).map { Line(at: $0.row, vertical: false, source: $0.source) }
            let columns = stacked.enumerated().filter { $1.touching.contains(i) }.flatMap { k, s in
                Arrangement.columns(on: displays[i].frame, of: s.placed).map { Line(at: $0, vertical: true, source: ids.count + k) }
            }
            draw(rows + columns, on: id, at: displays[i].frame)
        }
        // On the stacked display as it is now, where the edges of the displays it touches will fall once it's moved.
        for s in stacked {
            let columns = s.touching.flatMap { h in
                Arrangement.columns(on: s.placed, of: displays[h].frame).map { Line(at: $0, vertical: true, source: h) }
            }
            draw(columns, on: s.id, at: s.frame)
        }
    }

    static func hide() { panels.values.forEach { $0.orderOut(nil) } }

    /// Puts `id`'s panel over `f` (Quartz's frame, which updates before AppKit's screen list after a reorder).
    private static func draw(_ lines: [Line], on id: CGDirectDisplayID, at f: CGRect) {
        let panel = panels[id] ?? makePanel()
        panels[id] = panel
        let frame = CGRect(x: f.minX, y: CGDisplayBounds(CGMainDisplayID()).height - f.maxY, width: f.width, height: f.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        (panel.contentView as? GuideLinesView)?.lines = lines
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

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

/// A guide line `at` points from the display's top (a row) or left (a column), in its source display's color.
private struct Line: Equatable {
    let at: CGFloat
    let vertical: Bool
    let source: Int
}

/// Full-length lines, snapped to device pixels and kept inside the edges.
private final class GuideLinesView: NSView {
    var lines: [Line] = [] {
        didSet { if lines != oldValue { needsDisplay = true } }
    }
    private static let thickness: CGFloat = 2

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for line in lines {
            GuideOverlay.color(line.source).setFill()
            let rect = line.vertical
                ? CGRect(x: min(max(line.at - Self.thickness / 2, 0), bounds.width - Self.thickness), y: 0, width: Self.thickness, height: bounds.height)
                : CGRect(x: 0, y: min(max(line.at - Self.thickness / 2, 0), bounds.height - Self.thickness), width: bounds.width, height: Self.thickness)
            backingAlignedRect(rect, options: .alignAllEdgesNearest).fill()
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
