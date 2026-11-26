import CoreGraphics

/// One display: its frame in global points (top-left origin, as `CGDisplayBounds` returns), its physical scale,
/// and where it sits on the desk.
public struct Display: Sendable, Equatable {
    public let frame: CGRect
    /// Millimetres per point. Pixels are assumed square, so the width alone sets the scale for both axes.
    public let mmPerPoint: CGFloat
    /// Physical top edge in mm, measured down an axis shared by all displays. Only differences matter.
    public var topMM: CGFloat

    public init(frame: CGRect, widthMM: CGFloat, topMM: CGFloat = 0) {
        self.frame = frame
        mmPerPoint = widthMM / frame.width
        self.topMM = topMM
    }

    public var widthMM: CGFloat { frame.width * mmPerPoint }
    public var heightMM: CGFloat { frame.height * mmPerPoint }
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
/// and so every point of a shared edge can cross (clamping where one display is taller).
public struct Layout: Sendable {
    public let displays: [Display]
    static let landingInset: CGFloat = 3

    public init(displays: [Display]) {
        self.displays = displays
    }

    /// Where the cursor should land for a move from `prev` to `next` (as macOS placed it, possibly clamped),
    /// with `delta` the event's own movement. Returns nil when macOS's own placement is fine.
    public func remap(from prev: CGPoint, to next: CGPoint, delta: CGVector) -> CGPoint? {
        // After another app warps the cursor, `prev` is stale: fall back to the event's own delta.
        let jumped = hypot(next.x - prev.x, next.y - prev.y) > hypot(delta.dx, delta.dy) + 100
        let prev = jumped ? CGPoint(x: next.x - delta.dx, y: next.y - delta.dy) : prev
        let dx = delta.dx
        guard let src = displays.first(where: { $0.frame.contains(prev) }) else { return nil }
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

    /// Distance in points from `p` to the nearest edge where two displays sit side by side, or nil when
    /// no displays do. An edge spans the full height of both displays, since `remap` clamps onto the shorter one.
    public func distanceToSharedEdge(_ p: CGPoint) -> CGFloat? {
        displays.flatMap { a in
            displays.filter { Self.borders(a.frame, $0.frame) }.map { b in
                let top = min(a.frame.minY, b.frame.minY), bottom = max(a.frame.maxY, b.frame.maxY)
                return hypot(p.x - a.frame.maxX, max(top - p.y, p.y - bottom, 0))
            }
        }.min()
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
