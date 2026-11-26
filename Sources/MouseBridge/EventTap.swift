import AppKit
import OSLog
import BridgeCore
@preconcurrency import CoreGraphics

/// Owns the HID event taps. Remaps left/right display crossings through `Layout`
/// and turns the keyboard brightness keys into `onBrightnessKey` calls.
@MainActor @Observable
final class EventTap {
    var bridgeEnabled = UserDefaults.standard.object(forKey: "bridgeEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bridgeEnabled, forKey: "bridgeEnabled"); rebuildLayout() }
    }
    /// The displays with physical sizes, as arranged on the desk (see `Desk`).
    @ObservationIgnored var displays: [Display] = [] {
        didSet { rebuildLayout() }
    }
    /// False until Accessibility permission lets the tap start.
    private(set) var running = false

    @ObservationIgnored var onBrightnessKey: ((_ up: Bool, _ fine: Bool) -> Void)?
    @ObservationIgnored private var keyTap: CFMachPort?
    @ObservationIgnored private var mouseTap: CFMachPort?
    @ObservationIgnored private var gate: TapGate?
    /// Uptime (ns) of the last mouse event seen.
    @ObservationIgnored private var lastSeen: UInt64 = 0
    @ObservationIgnored private var layout: Layout?
    @ObservationIgnored private var last = CGEvent(source: nil)?.location ?? .zero
    /// Events left to log after a remap. Stream with: log stream --level debug --predicate 'subsystem == "it.realdoc06.mousebridge"'
    @ObservationIgnored private var trace = 0
    @ObservationIgnored private let log = Logger(subsystem: "it.realdoc06.mousebridge", category: "bridge")

    /// NX_SYSDEFINED: media and brightness keys.
    private static let systemDefined: UInt32 = 14

    /// A warp normally mutes real mouse input for 0.25 s, which freezes the cursor after each crossing.
    /// Zeroing the session's suppression interval removes that; the source must stay alive.
    @ObservationIgnored private let warpSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// Starts the taps. Fails until the app has Accessibility permission.
    /// Brightness keys and mouse moves get separate taps so `TapGate` can switch the mouse one off
    /// away from shared edges while the keys keep working.
    @discardableResult
    func start() -> Bool {
        if running { return true }
        let moves = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let keys = makeTap(1 << Self.systemDefined) else { return false }
        guard let mouse = makeTap(moves) else { CFMachPortInvalidate(keys); return false }
        keyTap = keys
        mouseTap = mouse
        gate = TapGate(mouse, layout: layout)
        running = true
        return true
    }

    private func makeTap(_ mask: CGEventMask) -> CFMachPort? {
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                let tap = Unmanaged<EventTap>.fromOpaque(info!).takeUnretainedValue()
                return MainActor.assumeIsolated { tap.handle(type, event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return port
    }

    private func rebuildLayout() {
        guard bridgeEnabled else { layout = nil; gate?.layout = nil; return }
        layout = Layout(displays: displays)
        gate?.layout = layout
        last = CGEvent(source: nil)?.location ?? last
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            // On is the safe state; the gate switches the mouse tap off again within one poll if it should be.
            [keyTap, mouseTap].compactMap { $0 }.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
        case .tapDisabledByUserInput:
            // Also sent when the gate switches the mouse tap off, so only the key tap is re-enabled here.
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
        case _ where type.rawValue == Self.systemDefined:
            if handleBrightnessKey(event) { return nil }
        default:
            bridge(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func bridge(_ event: CGEvent) {
        let next = event.location
        let delta = CGVector(
            dx: event.getDoubleValueField(.mouseEventDeltaX),
            dy: event.getDoubleValueField(.mouseEventDeltaY)
        )
        // After a gap in events `last` may be stale (the gate had the tap off). If it also disagrees with
        // this move, derive the start from the move itself.
        let now = DispatchTime.now().uptimeNanoseconds
        let stale = now - lastSeen > 30_000_000 && (delta.dx != 0 || delta.dy != 0)
            && hypot(next.x - last.x, next.y - last.y) > hypot(delta.dx, delta.dy) + 2
        let prev = stale ? CGPoint(x: next.x - delta.dx, y: next.y - delta.dy) : last
        lastSeen = now
        last = next
        if trace > 0 {
            trace -= 1
            log.debug("after: \(next.x, format: .fixed(precision: 1)),\(next.y, format: .fixed(precision: 1)) d \(delta.dx),\(delta.dy) t \(event.timestamp)")
        }
        guard let target = layout?.remap(from: prev, to: next, delta: delta) else { return }
        log.debug("remap: \(prev.x),\(prev.y) -> \(next.x),\(next.y) d \(delta.dx),\(delta.dy) => \(target.x),\(target.y) t \(event.timestamp)")
        trace = 8
        last = target
        event.location = target
        CGWarpMouseCursorPosition(target)
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

/// macOS hands the mouse tap every move, which is most of the app's CPU, so the tap only runs while the
/// cursor rests (no events, so free, and a flick from rest is always seen) or is near an edge where displays
/// meet. A background poll (60 Hz while the cursor moves, 20 Hz at rest) switches it, with a margin of 800 pt
/// plus 0.1 s of travel at the current speed, so a fast or accelerating move can't jump past it between polls. Polling off the main thread keeps SwiftUI's
/// run loop asleep. Lives as long as the app.
private final class TapGate: @unchecked Sendable {
    /// Read and written on `queue` only, except `layout`, which takes the lock.
    private let tap: CFMachPort
    private let queue = DispatchQueue(label: "it.realdoc06.mousebridge.gate", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var _layout: Layout?
    private var polled: (point: CGPoint, time: UInt64)?
    /// Keeps macOS from napping the app and delaying polls; the edge margin assumes they run on time.
    private let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Cursor bridge edge polling")
    /// Polls slower while the cursor rests, since every wakeup costs CPU.
    private static let moving = DispatchTimeInterval.milliseconds(16)
    private static let still = DispatchTimeInterval.milliseconds(50)
    private var interval = moving

    var layout: Layout? {
        get { lock.withLock { _layout } }
        set { lock.withLock { _layout = newValue } }
    }

    init(_ tap: CFMachPort, layout: Layout?) {
        self.tap = tap
        _layout = layout
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    private func tick() {
        let p = CGEvent(source: nil)?.location ?? .zero
        let now = DispatchTime.now().uptimeNanoseconds
        // Speed in points per second, measured over the real time since the last poll.
        let speed: CGFloat = polled.map { hypot(p.x - $0.point.x, p.y - $0.point.y) / max(CGFloat(now - $0.time) / 1e9, 0.001) } ?? 0
        let wait = p == polled?.point ? Self.still : Self.moving
        if wait != interval {
            interval = wait
            timer.schedule(deadline: .now() + wait, repeating: wait, leeway: .milliseconds(4))
        }
        polled = (p, now)
        let near = layout.map { layout in
            wait == Self.still || layout.distanceToSharedEdge(p).map { $0 < 800 + speed * 0.1 } == true
        } ?? false
        guard near != CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: near)
    }
}
