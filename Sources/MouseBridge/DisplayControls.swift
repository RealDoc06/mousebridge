import AppKit
import IOKit

/// HDR switching through SkyLight's private API, the call behind System Settings' HDR toggle.
enum HDR {
    private typealias Query = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Set = @convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> CGError
    nonisolated(unsafe) private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let supports = dlsym(skyLight, "SLSDisplaySupportsHDRMode").map { unsafeBitCast($0, to: Query.self) }
    private static let enabled = dlsym(skyLight, "SLSDisplayIsHDRModeEnabled").map { unsafeBitCast($0, to: Query.self) }
    private static let set = dlsym(skyLight, "SLSDisplaySetHDRModeEnabled").map { unsafeBitCast($0, to: Set.self) }

    static func isSupported(_ id: CGDirectDisplayID) -> Bool { set != nil && supports?(id) == true }
    static func isEnabled(_ id: CGDirectDisplayID) -> Bool { enabled?(id) == true }
    static func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) { _ = set?(id, on, 0, 0) }
}

/// Software dimming for displays without DDC: scales the gamma ramp's maximum.
enum Gamma {
    /// Displays drawn by a GPU framebuffer, the only ones gamma ramps reach. Framebuffers are matched to displays
    /// by EDID vendor and model. Virtual displays (Sidecar, AirPlay) have none and are dimmed by `Shade`.
    static func reachable() -> Set<CGDirectDisplayID> {
        var products: Set<Product> = []
        var iterator = io_iterator_t()
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator) == KERN_SUCCESS {
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                Product(framebuffer: entry).map { products.insert($0) }
                IOObjectRelease(entry)
            }
            IOObjectRelease(iterator)
        }
        return Set(activeDisplays().filter { CGDisplayIsBuiltin($0) != 0 || products.contains(Product($0)) })
    }

    static func dim(_ id: CGDirectDisplayID, to level: Double) {
        let max = Float(level)
        CGSetDisplayTransferByFormula(id, 0, max, 1, 0, max, 1, 0, max, 1)
    }

    /// Puts every display back on its ColorSync profile. Called on quit.
    static func restore() { CGDisplayRestoreColorSyncSettings() }
}

/// Software dimming for virtual displays, which gamma ramps don't reach: a click-through black panel over the
/// whole display, more opaque the dimmer it is. It can't change the device's own backlight (an iPad's stays as set
/// on the iPad), and it shows in screenshots. The cursor stays bright.
@MainActor
enum Shade {
    private static var panels: [CGDirectDisplayID: NSPanel] = [:]

    static func dim(_ id: CGDirectDisplayID, to level: Double) {
        guard level < 1 else { panels.removeValue(forKey: id)?.orderOut(nil); return }
        let panel = panels[id] ?? makePanel()
        panels[id] = panel
        // Placed from Quartz's frame, flipped into AppKit's bottom-left coordinates.
        let f = CGDisplayBounds(id), mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        panel.setFrame(CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height), display: false)
        panel.alphaValue = 1 - level
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Drops the panels of displays not in `ids`, e.g. after one disconnects.
    static func keep(_ ids: [CGDirectDisplayID]) {
        for (id, panel) in panels where !ids.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
    }

    /// Above the menu bar, Dock and full screen apps, below the brightness HUD.
    static let level = NSWindow.Level.screenSaver

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = level
        panel.backgroundColor = .black
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}
