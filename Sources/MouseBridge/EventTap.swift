import AppKit
import BridgeCore
@preconcurrency import CoreGraphics

/// Owns the HID event tap. Remaps left/right display crossings through `Layout`
/// and turns the keyboard brightness keys into `onBrightnessKey` calls.
@MainActor @Observable
final class EventTap {
    var bridgeEnabled = UserDefaults.standard.object(forKey: "bridgeEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bridgeEnabled, forKey: "bridgeEnabled"); rebuildLayout() }
    }
    /// How the displays line up physically on the desk.
    var alignment = Alignment(rawValue: UserDefaults.standard.string(forKey: "alignment") ?? "") ?? .bottom {
        didSet { UserDefaults.standard.set(alignment.rawValue, forKey: "alignment"); rebuildLayout() }
    }
    /// False until Accessibility permission lets the tap start.
    private(set) var running = false

    @ObservationIgnored var onBrightnessKey: ((_ up: Bool, _ fine: Bool) -> Void)?
    @ObservationIgnored private var port: CFMachPort?
    @ObservationIgnored private var layout: Layout?
    @ObservationIgnored private var last = CGEvent(source: nil)?.location ?? .zero

    /// NX_SYSDEFINED: media and brightness keys.
    private static let systemDefined: UInt32 = 14

    init() { rebuildLayout() }

    /// Starts the tap. Fails until the app has Accessibility permission.
    @discardableResult
    func start() -> Bool {
        if running { return true }
        let types = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].map(\.rawValue)
            + [Self.systemDefined]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1) }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                let tap = Unmanaged<EventTap>.fromOpaque(info!).takeUnretainedValue()
                return MainActor.assumeIsolated { tap.handle(type, event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        running = true
        return true
    }

    /// Re-reads display geometry and physical sizes. Call after the display setup changes.
    func rebuildLayout() {
        guard bridgeEnabled else { layout = nil; return }
        let displays = activeDisplays().compactMap { id -> Display? in
            let mm = CGDisplayScreenSize(id)
            guard mm.width > 0 else { return nil } // no physical size reported: leave this display to macOS
            return Display(frame: CGDisplayBounds(id), widthMM: mm.width)
        }
        layout = Layout(displays: displays, alignment: alignment)
        last = CGEvent(source: nil)?.location ?? last
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case _ where type.rawValue == Self.systemDefined:
            if handleBrightnessKey(event) { return nil }
        default:
            bridge(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func bridge(_ event: CGEvent) {
        let next = event.location
        defer { last = event.location }
        let delta = CGVector(
            dx: event.getDoubleValueField(.mouseEventDeltaX),
            dy: event.getDoubleValueField(.mouseEventDeltaY)
        )
        guard let target = layout?.remap(from: last, to: next, delta: delta) else { return }
        event.location = target
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1) // cancels the post-warp input freeze
    }

    /// Brightness keys arrive as NX_SYSDEFINED subtype 8 with key type 2 (up) or 3 (down) in data1.
    /// Returns true when the event was a brightness key, so it is swallowed.
    private func handleBrightnessKey(_ event: CGEvent) -> Bool {
        guard let onBrightnessKey, let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else { return false }
        let code = (key.data1 & 0xFFFF_0000) >> 16
        guard code == 2 || code == 3 else { return false }
        if (key.data1 & 0xFF00) >> 8 == 0x0A { // key down, including repeats
            onBrightnessKey(code == 2, key.modifierFlags.contains([.option, .shift]))
        }
        return true
    }
}
