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

    /// Heights (mm) where a top, center or bottom edge of one display lines up with one of another,
    /// within `tolerance`. Each shared height is listed once.
    public static func guides(_ displays: [Display], tolerance: CGFloat = 0.5) -> [CGFloat] {
        var found: [CGFloat] = []
        for (i, a) in displays.enumerated() {
            for b in displays[(i + 1)...] {
                for la in levels(of: a.heightMM).map({ $0 + a.topMM }) {
                    let aligned = levels(of: b.heightMM).contains { abs($0 + b.topMM - la) <= tolerance }
                    if aligned, !found.contains(where: { abs($0 - la) <= tolerance }) { found.append(la) }
                }
            }
        }
        return found
    }

    /// Top, center and bottom of a display `height` tall, relative to its top.
    private static func levels(of height: CGFloat) -> [CGFloat] { [0, height / 2, height] }
}
