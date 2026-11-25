import CoreGraphics

/// One display: its frame in global points (top-left origin, as `CGDisplayBounds` returns) and its physical scale.
public struct Display: Sendable, Equatable {
    public let frame: CGRect
    /// Millimetres per point. Pixels are assumed square, so the width alone sets the scale for both axes.
    public let mmPerPoint: CGFloat

    public init(frame: CGRect, widthMM: CGFloat) {
        self.frame = frame
        mmPerPoint = widthMM / frame.width
    }

    var heightMM: CGFloat { frame.height * mmPerPoint }
}

/// How side-by-side displays line up physically on the desk.
public enum Alignment: String, Sendable, CaseIterable {
    case top, center, bottom
}

/// Remaps horizontal edge crossings so the cursor keeps its physical height,
/// and so every point of a shared edge can cross (clamping where one display is taller).
public struct Layout: Sendable {
    public let displays: [Display]
    public let alignment: Alignment
    private let tallestMM: CGFloat
    static let landingInset: CGFloat = 3

    public init(displays: [Display], alignment: Alignment) {
        self.displays = displays
        self.alignment = alignment
        tallestMM = displays.map(\.heightMM).max() ?? 0
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
        let neighbors = displays.filter {
            abs(left ? $0.frame.maxX - src.frame.minX : $0.frame.minX - src.frame.maxX) < 1
        }

        let y = min(max(next.y, src.frame.minY), src.frame.maxY - 1)
        let mm = top(of: src) + (y - src.frame.minY) * src.mmPerPoint
        guard let dst = neighbors.min(by: { gap(mm, $0) < gap(mm, $1) }) else { return nil }

        let localMM = min(max(mm - top(of: dst), 0), dst.heightMM)
        // Land a few points inside the destination so sensor jitter can't bounce the cursor straight back.
        return CGPoint(
            x: left ? dst.frame.maxX - 1 - Self.landingInset : dst.frame.minX + Self.landingInset,
            y: min(dst.frame.minY + localMM / dst.mmPerPoint, dst.frame.maxY - 1)
        )
    }

    /// Physical top edge of `d` in mm, measured down from the tallest display's top.
    private func top(of d: Display) -> CGFloat {
        switch alignment {
        case .top: 0
        case .center: (tallestMM - d.heightMM) / 2
        case .bottom: tallestMM - d.heightMM
        }
    }

    /// Vertical distance in mm from `mm` to `d`'s physical span, 0 when inside it.
    private func gap(_ mm: CGFloat, _ d: Display) -> CGFloat {
        let t = top(of: d)
        return max(t - mm, mm - (t + d.heightMM), 0)
    }
}
