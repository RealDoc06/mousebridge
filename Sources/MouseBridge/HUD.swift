import AppKit
import SwiftUI

/// A small brightness bar near the bottom of a display, shown after a brightness key press.
@MainActor
enum HUD {
    private static let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = Shade.level + 1
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }()
    private static var generation = 0

    static func show(_ level: Double, on display: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return }
        let size = CGSize(width: 240, height: 40)
        panel.contentView = NSHostingView(rootView: HUDView(level: level))
        panel.setFrame(
            CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.12, width: size.width, height: size.height),
            display: true
        )
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        generation += 1
        let shown = generation
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard shown == generation else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 0 }
            if shown == generation { panel.orderOut(nil) }
        }
    }
}

private struct HUDView: View {
    let level: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max.fill")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: geo.size.width * level)
                }
            }
            .frame(height: 6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: RoundedRectangle(cornerRadius: 10))
    }
}
