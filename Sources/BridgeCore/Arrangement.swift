import CoreGraphics

/// Geometry for arranging displays by hand at physical scale: where a dragged display may go,
/// which edges it snaps to, and which edges line up.
public enum Arrangement {
    /// How far past the others' combined span a display may be dragged, as a fraction of its own height.
    /// A canvas padded by this much of the tallest display above and below the arrangement fits any drag.
    public static let overhang: CGFloat = 0.25

    /// The top (mm) `displays[index]` takes when dragged to `top`. It stays beside the others, sticking out
    /// past their combined span by at most `overhang` of its height. With `snapMM`, its top, center or bottom
    /// snaps to the nearest top, center or bottom of another display within that distance.
    public static func place(_ index: Int, at top: CGFloat, in displays: [Display], snapMM: CGFloat? = nil) -> CGFloat {
        let others = displays.indices.filter { $0 != index }.map { displays[$0] }
        guard !others.isEmpty else { return top }
        let h = displays[index].heightMM
        let range = (others.map(\.topMM).min()! - h * overhang)...(others.map { $0.topMM + $0.heightMM }.max()! - h * (1 - overhang))
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
