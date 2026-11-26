import CoreGraphics

/// One display: its frame in global points (top-left origin, as `CGDisplayBounds` returns), its physical scale,
/// and where it sits on the desk.
public struct Display: Sendable, Equatable {
    public let frame: CGRect
    /// Millimetres per point. Pixels are assumed square, so the width alone sets the scale for both axes.
    public let mmPerPoint: CGFloat
    /// Physical top edge in mm, measured down an axis shared by all displays. Only differences matter.
    public var topMM: CGFloat
    /// Physical left edge in mm, measured along the desk from the row's left end. Vertical crossings between the row
    /// and a display stacked above or below it follow it.
    public var leftMM: CGFloat

    public init(frame: CGRect, widthMM: CGFloat, topMM: CGFloat = 0, leftMM: CGFloat = 0) {
        self.frame = frame
        mmPerPoint = widthMM / frame.width
        self.topMM = topMM
        self.leftMM = leftMM
    }

    public var widthMM: CGFloat { frame.width * mmPerPoint }
    public var heightMM: CGFloat { frame.height * mmPerPoint }

    /// True when the desk position `mm` (along `leftMM`'s axis) is in front of this display.
    public func spans(_ mm: CGFloat) -> Bool { leftMM <= mm && mm < leftMM + widthMM }
}

/// Preset ways side-by-side displays line up on the desk. Seeds `Display.topMM` for displays not yet arranged.
public enum Alignment: String, Sendable {
    case top, center, bottom

    /// Top edge of a display `heightMM` tall, measured down from the top of one `tallestMM` tall.
    public func top(heightMM: CGFloat, tallestMM: CGFloat) -> CGFloat {
        switch self {
        case .top: 0
        case .center: (tallestMM - heightMM) / 2
        case .bottom: tallestMM - heightMM
        }
    }
}

/// Remaps horizontal edge crossings so the cursor keeps its physical height,
/// and so every point of a shared edge can cross (clamping where one display is taller). Crossings between the
/// row and a display stacked above or below it keep the cursor's physical position along the desk instead.
public struct Layout: Sendable {
    public let displays: [Display]
    /// Displays stacked above or below `displays` on their own, like an iPad under a monitor.
    public let stacked: [Stacked]
    static let landingInset: CGFloat = 3

    /// A display stacked on the row, and whether it sits below it (or above).
    public struct Stacked: Sendable, Equatable {
        public let display: Display
        public let below: Bool

        public init(_ display: Display, below: Bool) {
            self.display = display
            self.below = below
        }
    }

    public init(displays: [Display], stacked: [Stacked] = []) {
        self.displays = displays
        self.stacked = stacked
    }

    /// Where the cursor should land for a move from `prev` to `next` (as macOS placed it, possibly clamped),
    /// with `delta` the event's own movement. Returns nil when macOS's own placement is fine.
    public func remap(from prev: CGPoint, to next: CGPoint, delta: CGVector) -> CGPoint? {
        // After another app warps the cursor, `prev` is stale: fall back to the event's own delta.
        let jumped = hypot(next.x - prev.x, next.y - prev.y) > hypot(delta.dx, delta.dy) + 100
        let prev = jumped ? CGPoint(x: next.x - delta.dx, y: next.y - delta.dy) : prev
        return across(from: prev, to: next, delta: delta) ?? between(from: prev, to: next, delta: delta)
    }

    /// A left or right crossing between side-by-side displays, at the same physical height.
    private func across(from prev: CGPoint, to next: CGPoint, delta: CGVector) -> CGPoint? {
        let dx = delta.dx
        guard let src = displays.first(where: { $0.frame.contains(prev) }),
              // A crossing macOS put onto a display left out of `displays` (one stacked above or below) is left alone.
              displays.contains(where: { $0.frame.contains(next) }) else { return nil }
        let left: Bool
        if dx != 0 { left = dx < 0 } else if next.x != prev.x { left = next.x < prev.x } else { return nil }

        let atEdge = left ? next.x < src.frame.minX + 1 : next.x >= src.frame.maxX - 1
        guard atEdge else { return nil }
        let neighbors = displays.filter { left ? Self.borders($0.frame, src.frame) : Self.borders(src.frame, $0.frame) }

        let y = min(max(next.y, src.frame.minY), src.frame.maxY - 1)
        let mm = src.topMM + (y - src.frame.minY) * src.mmPerPoint
        guard let dst = neighbors.min(by: { gap(mm, $0) < gap(mm, $1) }) else { return nil }

        let localMM = min(max(mm - dst.topMM, 0), dst.heightMM)
        // Land a few points inside the destination so sensor jitter can't bounce the cursor straight back.
        return CGPoint(
            x: left ? dst.frame.maxX - 1 - Self.landingInset : dst.frame.minX + Self.landingInset,
            y: min(dst.frame.minY + localMM / dst.mmPerPoint, dst.frame.maxY - 1)
        )
    }

    /// An up or down crossing between the row and a stacked display, at the same position along the desk. The cursor
    /// crosses only where the stacked display physically sits, wherever macOS has it in points: onto it where it is
    /// in front of the cursor, and not at all where it isn't, even where macOS would let it through.
    private func between(from prev: CGPoint, to next: CGPoint, delta: CGVector) -> CGPoint? {
        let dy = delta.dy != 0 ? delta.dy : next.y - prev.y
        guard dy != 0 else { return nil }
        let down = dy > 0
        if let src = displays.first(where: { $0.frame.contains(prev) }) {
            // From the row toward a display stacked on that side.
            let targets = stacked.filter { $0.below == down }.map(\.display)
            guard !targets.isEmpty, let (x, mm) = edge(of: src, at: next, down: down) else { return nil }
            if let dst = targets.first(where: { $0.spans(mm) }) { return land(on: dst, at: mm, down: down) }
            // Nothing physically there: keep the cursor on the row even where macOS put it on the stacked display.
            return targets.contains { $0.frame.contains(next) } ? CGPoint(x: x, y: down ? src.frame.maxY - 1 : src.frame.minY) : nil
        }
        if let src = stacked.first(where: { $0.display.frame.contains(prev) }), src.below != down {
            // From a stacked display back toward the row: onto the nearest row display in front of the cursor.
            guard let (x, mm) = edge(of: src.display, at: next, down: down) else { return nil }
            let side = displays.filter { down ? $0.frame.minY >= src.display.frame.maxY - 1 : $0.frame.maxY <= src.display.frame.minY + 1 }
            let dst = side.filter { $0.spans(mm) }.min { abs(nearY($0, down) - next.y) < abs(nearY($1, down) - next.y) }
            if let dst { return land(on: dst, at: mm, down: down) }
            let edgeY = down ? src.display.frame.maxY - 1 : src.display.frame.minY
            return side.contains { $0.frame.contains(next) } ? CGPoint(x: x, y: edgeY) : nil
        }
        return nil
    }

    /// The column (x) and desk position (mm) where the cursor meets `src`'s bottom (or top) edge, or nil when it
    /// hasn't reached it. macOS either clamps the cursor there or has already moved it past.
    private func edge(of src: Display, at next: CGPoint, down: Bool) -> (CGFloat, CGFloat)? {
        guard down ? next.y >= src.frame.maxY - 1 : next.y < src.frame.minY + 1 else { return nil }
        let x = min(max(next.x, src.frame.minX), src.frame.maxX - 1)
        return (x, src.leftMM + (x - src.frame.minX) * src.mmPerPoint)
    }

    /// Lands a few points inside `dst`'s top (or bottom) edge at desk position `mm`, so jitter can't bounce it back.
    private func land(on dst: Display, at mm: CGFloat, down: Bool) -> CGPoint {
        CGPoint(
            x: min(max(dst.frame.minX + (mm - dst.leftMM) / dst.mmPerPoint, dst.frame.minX), dst.frame.maxX - 1),
            y: down ? dst.frame.minY + Self.landingInset : dst.frame.maxY - 1 - Self.landingInset
        )
    }

    private func nearY(_ d: Display, _ down: Bool) -> CGFloat { down ? d.frame.minY : d.frame.maxY }

    /// Distance in points from `p` to the nearest edge the bridge handles, or nil when there is none: where two
    /// displays sit side by side (spanning the full height of both, since `remap` clamps onto the shorter one), and
    /// the row's whole bottom (or top) edge toward a stacked display, since the cursor may cross anywhere along it.
    public func distanceToSharedEdge(_ p: CGPoint) -> CGFloat? {
        let sides = displays.flatMap { a in
            displays.filter { Self.borders(a.frame, $0.frame) }.map { b in
                let top = min(a.frame.minY, b.frame.minY), bottom = max(a.frame.maxY, b.frame.maxY)
                return hypot(p.x - a.frame.maxX, max(top - p.y, p.y - bottom, 0))
            }
        }
        let frames = displays.map(\.frame)
        let ends = stacked.map { s in
            let all = frames + [s.display.frame]
            let lo = all.map(\.minX).min() ?? 0, hi = all.map(\.maxX).max() ?? 0
            return hypot(max(lo - p.x, p.x - hi, 0), p.y - (s.below ? s.display.frame.minY : s.display.frame.maxY))
        }
        return (sides + ends).min()
    }

    /// True when `b` sits directly right of `a` in global points with rows in common: an edge the cursor crosses.
    /// A display stacked above or below `b` with no rows beside `a` doesn't count.
    public static func borders(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(b.minX - a.maxX) < 1 && a.minY < b.maxY && b.minY < a.maxY
    }

    /// True when `b` sits directly below `a` in global points with columns in common: an edge macOS itself crosses.
    public static func stacks(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(b.minY - a.maxY) < 1 && a.minX < b.maxX && b.minX < a.maxX
    }

    /// Vertical distance in mm from `mm` to `d`'s physical span, 0 when inside it.
    private func gap(_ mm: CGFloat, _ d: Display) -> CGFloat {
        max(d.topMM - mm, mm - (d.topMM + d.heightMM), 0)
    }
}
