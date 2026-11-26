import AppKit
import BridgeCore
import SwiftUI

/// Yellow lines drawn over the real displays while arranging with guides on. Each display shows the top, center
/// and bottom of the others at their physical height (`Arrangement.guides(on:in:)`), so a line that runs level
/// into the neighbor's actual bezel edge means the arrangement matches the desk. Clicks pass through.
@MainActor
enum GuideOverlay {
    private static var panels: [CGDirectDisplayID: NSPanel] = [:]

    /// Shows the lines for `displays` (as arranged, with any drag in progress), indexed like `ids`.
    static func show(_ ids: [CGDirectDisplayID], _ displays: [Display]) {
        for (i, id) in ids.enumerated() {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { continue }
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            panel.setFrame(screen.frame, display: false)
            panel.contentView = NSHostingView(rootView: GuideLines(rows: Arrangement.guides(on: i, in: displays)))
            panel.orderFrontRegardless()
        }
        for (id, panel) in panels where !ids.contains(id) { panel.orderOut(nil) }
    }

    static func hide() { panels.values.forEach { $0.orderOut(nil) } }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

/// Full-width lines at `rows`, in points from the top of the screen, kept inside its edges.
private struct GuideLines: View {
    let rows: [CGFloat]
    private static let thickness: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            ForEach(rows, id: \.self) { row in
                Rectangle().fill(.yellow)
                    .frame(width: geo.size.width, height: Self.thickness)
                    .offset(y: min(max(row - Self.thickness / 2, 0), geo.size.height - Self.thickness))
            }
        }
    }
}

/// Calls `action` with whether the window holding this view is on screen, as it opens and closes.
/// A MenuBarExtra popup keeps its views alive while closed, so `onAppear` and `onDisappear` miss that.
struct OnWindowVisibility: NSViewRepresentable {
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ view: VisibilityView, context: Context) { view.action = action }

    final class VisibilityView: NSView {
        var action: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            observer.map(NotificationCenter.default.removeObserver)
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.action?(window.occlusionState.contains(.visible))
                }
            }
        }
    }
}
