import CoreGraphics

/// Geometry for arranging displays by hand at physical scale: where a dragged display may go,
/// which edges it snaps to, and which edges line up.
public enum Arrangement {
    /// The top (mm) `displays[index]` takes when dragged to `top`. It stays beside the others, overlapping
    /// their combined span by at least half its height. With `snapMM`, its top, center or bottom snaps to the
    /// nearest top, center or bottom of another display within that distance.
    public static func place(_ index: Int, at top: CGFloat, in displays: [Display], snapMM: CGFloat? = nil) -> CGFloat {
        let others = displays.indices.filter { $0 != index }.map { displays[$0] }
        guard !others.isEmpty else { return top }
        let half = displays[index].heightMM / 2
        let range = (others.map(\.topMM).min()! - half)...(others.map { $0.topMM + $0.heightMM }.max()! - half)
        let top = min(max(top, range.lowerBound), range.upperBound)
        guard let snapMM else { return top }
        let mine = levels(of: displays[index].heightMM).map { $0 + top }
        let shifts = others.flatMap { d in levels(of: d.heightMM).map { $0 + d.topMM } }
            .flatMap { theirs in mine.map { theirs - $0 } }
            .filter { abs($0) <= snapMM && range.contains(top + $0) }
        return top + (shifts.min { abs($0) < abs($1) } ?? 0)
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
