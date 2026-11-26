import CoreGraphics

/// Geometry for arranging displays by hand at physical scale: where a dragged display may go,
/// which edges it snaps to, and which edges line up.
public enum Arrangement {
    /// How far a dragged display may stick out past the others' combined span, as a fraction of its own height.
    public static let overhang: CGFloat = 0.25

    /// The tops (mm) `displays[index]` can be dragged between, or nil when it is alone. It may stick out past
    /// the others' combined span by `overhang` of its height. A display taller than that span may cover it
    /// anywhere from bottom- to top-aligned, with the same slack.
    public static func reach(_ index: Int, in displays: [Display]) -> ClosedRange<CGFloat>? {
        let others = displays.indices.filter { $0 != index }.map { displays[$0] }
        guard let top = others.map(\.topMM).min(), let bottom = others.map({ $0.topMM + $0.heightMM }).max() else { return nil }
        let h = displays[index].heightMM
        return (min(top, bottom - h) - h * overhang)...(max(top, bottom - h) + h * overhang)
    }

    /// Vertical span (mm) covered by the displays and by any one of them dragged as far as it can go,
    /// so a canvas framed on it holds still during a drag.
    public static func bounds(_ displays: [Display]) -> ClosedRange<CGFloat> {
        let edges = displays.indices.flatMap { i in
            let d = displays[i], r = reach(i, in: displays) ?? d.topMM...d.topMM
            return [d.topMM, d.topMM + d.heightMM, r.lowerBound, r.upperBound + d.heightMM]
        }
        return (edges.min() ?? 0)...(edges.max() ?? 0)
    }

    /// The top (mm) `displays[index]` takes when dragged to `top`, kept within `reach` or between it and where
    /// the display already is, so a drag never moves a display that is already out of reach. With `snapMM`, its
    /// top, center or bottom snaps to the nearest top, center or bottom of another display within that distance.
    public static func place(_ index: Int, at top: CGFloat, in displays: [Display], snapMM: CGFloat? = nil) -> CGFloat {
        guard let reach = reach(index, in: displays) else { return top }
        let current = displays[index].topMM
        let range = min(reach.lowerBound, current)...max(reach.upperBound, current)
        let others = displays.indices.filter { $0 != index }.map { displays[$0] }
        let top = min(max(top, range.lowerBound), range.upperBound)
        guard let snapMM else { return top }
        let mine = levels(of: displays[index].heightMM).map { $0 + top }
        let shifts = others.flatMap { d in levels(of: d.heightMM).map { $0 + d.topMM } }
            .flatMap { theirs in mine.map { theirs - $0 } }
            .filter { abs($0) <= snapMM && range.contains(top + $0) }
        return top + (shifts.min { abs($0) < abs($1) } ?? 0)
    }

    /// Left-to-right order (indices into `widths`) when the display at `index` is dragged so its left edge is at
    /// `left` (mm, row starts at 0). It goes before the first other display whose midpoint it hasn't passed,
    /// with the others packed without it, so every swap point lies inside the row whatever the widths.
    public static func order(widths: [CGFloat], dragging index: Int, toLeft left: CGFloat) -> [Int] {
        var others = widths.indices.filter { $0 != index }
        var x: CGFloat = 0
        let slot = others.firstIndex { j in defer { x += widths[j] }; return left < x + widths[j] / 2 } ?? others.count
        others.insert(index, at: slot)
        return others
    }

    /// Rows (points from its top) of `displays[index]` that sit at the same physical height as the top, center or
    /// bottom of another display. Drawn on the real screen, a row that lines up with that display's actual edge
    /// across the bezel means the arrangement matches the desk. Rows past the display's own edges are left out.
    public static func guides(on index: Int, in displays: [Display]) -> [Guide] {
        let d = displays[index]
        let guides = displays.indices.filter { $0 != index }.flatMap { j in
            levels(of: displays[j].heightMM).map { Guide(row: ($0 + displays[j].topMM - d.topMM) / d.mmPerPoint, source: j) }
        }
        return guides.filter { (-0.5...(d.frame.height + 0.5)).contains($0.row) }
    }

    /// Columns (points from `frame`'s left) under or over the left edge, center and right edge of `other`, a display
    /// stacked against it: where the cursor crosses between the two in macOS. Drawn on the real screen, a column that
    /// runs straight into that display's actual bezel edge means the arrangement matches the desk. Columns past the
    /// display's own edges are left out.
    public static func columns(on frame: CGRect, of other: CGRect) -> [CGFloat] {
        [other.minX, other.midX, other.maxX].map { $0 - frame.minX }.filter { (-0.5...(frame.width + 0.5)).contains($0) }
    }

    /// A guide line: its row (points from the display's top) and the index of the display whose edge it marks.
    public struct Guide: Equatable, Sendable {
        public let row: CGFloat
        public let source: Int
    }

    /// Where a display with `frame` (global points), stacked above or below `host`, sits against it: its left edge
    /// in mm from the host's left edge, and whether it is below. It's measured at the host's scale, as macOS lines
    /// the two up in points, so it's drawn the size its resolution makes it next to the host and touches it exactly
    /// where the cursor crosses. Only the macOS arrangement matters for these displays.
    public static func stack(_ frame: CGRect, on host: Display) -> (leftMM: CGFloat, below: Bool) {
        ((frame.minX - host.frame.minX) * host.mmPerPoint, frame.midY > host.frame.midY)
    }

    /// The origin in global points that puts a display `size` big `leftMM` right of `host`'s left edge, touching
    /// its bottom or top: the inverse of `stack`. It slides clear of `others` (the host's row neighbors) where they
    /// reach into its rows, as Quartz would, and keeps a column on the host. Nil when no spot does both.
    public static func origin(
        stacking size: CGSize, leftMM: CGFloat, below: Bool, on host: Display, clearOf others: [CGRect] = []
    ) -> CGPoint? {
        let y = below ? host.frame.maxY : host.frame.minY - size.height
        var lowest = host.frame.minX - size.width + 1, highest = host.frame.maxX - 1
        for o in others where o.minY < y + size.height && y < o.maxY {
            if o.midX > host.frame.midX { highest = min(highest, o.minX - size.width) } else { lowest = max(lowest, o.maxX) }
        }
        guard lowest <= highest else { return nil }
        let x = host.frame.minX + leftMM / host.mmPerPoint
        return CGPoint(x: min(max(x.rounded(), lowest), highest), y: y)
    }

    /// The display (index into `spans`, each a left edge and width) that a span from `left`, `width` wide, overlaps
    /// the most: the one a dragged stacked display is dropped against. `host(of:among:)` then settles which display
    /// the resulting frame sits on.
    public static func host(left: CGFloat, width: CGFloat, in spans: [(left: CGFloat, width: CGFloat)]) -> Int? {
        let overlap = { (s: (left: CGFloat, width: CGFloat)) in min(left + width, s.left + s.width) - max(left, s.left) }
        return spans.indices.max { overlap(spans[$0]) < overlap(spans[$1]) }
    }

    /// The display in `frames` (global points) that `frame` is stacked on: of those whose top or bottom edge it
    /// touches, the one sharing the most columns. Nil when it touches none.
    public static func host(of frame: CGRect, among frames: [CGRect]) -> Int? {
        let columns = { (f: CGRect) in min(frame.maxX, f.maxX) - max(frame.minX, f.minX) }
        return frames.indices
            .filter { Layout.stacks(frames[$0], frame) || Layout.stacks(frame, frames[$0]) }
            .max { columns(frames[$0]) < columns(frames[$1]) }
    }

    /// Top, center and bottom of a display `height` tall, relative to its top.
    private static func levels(of height: CGFloat) -> [CGFloat] { [0, height / 2, height] }
}
