import BridgeCore
import SwiftUI

/// The side-by-side displays (`Desk.row`) at real scale, as on the desk. Dragging one up or down sets where it physically
/// sits, which the cursor bridge maps crossings by, and the arrows nudge the selected one a pixel at a time.
/// Dragging one past a neighbor reorders macOS's arrangement. With guides on, drags snap to aligned edges and
/// `GuideOverlay` draws the guides on the real displays, each display's in its own color. Displays stacked above or
/// below the row (`Desk.stacked`) sit against the one they touch at its scale, as macOS lines them up, and dragging
/// one moves it along that edge, onto another display, or to the other side, in macOS's arrangement only. Dragged
/// past either end of the row, it docks beside the end display and joins the row; an end display dragged past the
/// canvas's top or bottom leaves the row and stacks on its neighbor.
struct ArrangementView: View {
    let desk: Desk
    /// Label for each display, by display ID.
    let names: [CGDirectDisplayID: String]
    let width: CGFloat

    /// Resets by itself when a drag ends or is cancelled, e.g. by the popup closing.
    @GestureState private var drag: Drag?
    /// The display the arrows move: the last one tapped or dragged.
    @State private var selected: CGDirectDisplayID?
    /// Whether the popup is open. MenuBarExtra keeps this view alive while it's closed.
    @State private var open = false

    private struct Drag: Equatable {
        let id: CGDirectDisplayID
        var offset: CGSize
        /// The pointer, in the canvas's coordinate space (`space`).
        var location: CGPoint

        init(id: CGDirectDisplayID, _ value: DragGesture.Value) {
            self.id = id
            offset = value.translation
            location = value.location
        }
    }

    /// The canvas's coordinate space, which drags are measured in, so they hold steady while the canvas re-lays out.
    private static let space = "arrangement"

    /// Snap reach in points on screen, so it feels the same at any scale.
    private static let snapPoints: CGFloat = 6
    /// Tallest the canvas gets, in points.
    private static let maxHeight: CGFloat = 240

    var body: some View {
        // Until one is picked, the arrows move the first display that isn't the main one.
        let target = selected.flatMap { id in desk.row.first { $0.id == id } }?.id
            ?? desk.row.first { $0.id != CGMainDisplayID() }?.id
        Panel {
            Text("Arrangement")
            Spacer()
            // A display alone in the row has nothing to nudge against or line up with.
            if desk.row.count > 1 { controls(target: target) }
        } content: {
            canvas(target: target)
        }
    }

    /// The arrows that nudge the selected display a pixel, and the guides toggle.
    @ViewBuilder private func controls(target: CGDirectDisplayID?) -> some View {
        Group {
            Button("Move up", systemImage: "arrow.up") { target.map { nudge($0, pixels: -1) } }
                .help("Move the selected display up a pixel")
            Button("Move down", systemImage: "arrow.down") { target.map { nudge($0, pixels: 1) } }
                .help("Move the selected display down a pixel")
        }
        .buttonRepeatBehavior(.enabled)
        .foregroundStyle(.secondary)
        .fontWeight(.regular)
        Button("Guides", systemImage: "ruler") { desk.guides.toggle() }
            .foregroundStyle(desk.guides ? .yellow : .secondary)
            .help(desk.guides ? "Hide guides" : "Show guides on the displays")
            .fontWeight(.regular)
    }

    /// How the canvas maps mm to points, for a row laid out from 0 at `inset`.
    private struct Frame {
        let scale: CGFloat
        let inset: CGFloat
        /// mm at the canvas's top edge, and its height.
        let originMM: CGFloat
        let heightMM: CGFloat
        /// Row mm the canvas shows, including room past the row's ends for stacked displays hanging over.
        let span: ClosedRange<CGFloat>
    }

    /// Frames `row` with room for stacked displays (`frame` in points, on `host`, drawn at its scale): past the
    /// row's ends where one hangs over, and its full height above and below, since one can be dragged to either
    /// side. As wide as the panel, but no taller than `maxHeight` (a laptop with an iPad below would push the menu
    /// off screen), centered when that makes it narrower. Framed on the saved arrangement, so it holds still while
    /// a display moves.
    private func frame(row: [Display], stacked: [(frame: CGRect, host: Display)]) -> Frame {
        let rowWidth = row.map(\.widthMM).reduce(0, +)
        let overhangs = stacked.map { s in
            let left = Arrangement.stack(s.frame, on: s.host).leftMM
            return (left: -left, right: left + s.frame.width * s.host.mmPerPoint - s.host.widthMM)
        }
        let padLeft = overhangs.map(\.left).reduce(0, max), padRight = overhangs.map(\.right).reduce(0, max)
        let bounds = Arrangement.bounds(row)
        let tallest = stacked.map { $0.frame.height * $0.host.mmPerPoint }.max() ?? 0
        let widthMM = padLeft + rowWidth + padRight, heightMM = bounds.upperBound - bounds.lowerBound + 2 * tallest
        let scale = min(width / widthMM, Self.maxHeight / heightMM)
        return Frame(
            scale: scale, inset: (width - widthMM * scale) / 2 + padLeft * scale,
            originMM: bounds.lowerBound - tallest, heightMM: heightMM, span: -padLeft...(rowWidth + padRight)
        )
    }

    private enum End { case left, right }

    /// The row end a dragged stacked display docks beside: the one the pointer has left the canvas's content past.
    private func dock(_ drag: Drag?, in f: Frame) -> End? {
        guard let drag, desk.stacked.contains(where: { $0.screen.id == drag.id }) else { return nil }
        if drag.location.x < f.inset + f.span.lowerBound * f.scale { return .left }
        if drag.location.x > f.inset + f.span.upperBound * f.scale { return .right }
        return nil
    }

    /// A row end display lifted out of the row: its index, its neighbor's (which it stacks on), and its new frame.
    private struct Undock {
        let index: Int
        let host: Int
        let frame: CGRect
    }

    /// Where a dragged row end display stacks when the pointer leaves the canvas above or below: on its neighbor's
    /// top or bottom, lined up with the row's outer edge. Nil for a middle display, which would split the row, one
    /// with a display stacked on it, or when it doesn't fit there.
    private func undock(_ drag: Drag?, in f: Frame) -> Undock? {
        let row = desk.row.map(\.display)
        guard let drag, row.count > 1, let i = desk.row.firstIndex(where: { $0.id == drag.id }),
              i == 0 || i == row.count - 1, !desk.stacked.contains(where: { $0.host == i }),
              drag.location.y < 0 || drag.location.y > f.heightMM * f.scale else { return nil }
        let n = i == 0 ? 1 : i - 1, d = row[i]
        let origin = Arrangement.origin(
            stacking: d.frame.size, leftMM: i == 0 ? 0 : row[n].widthMM - d.frame.width * row[n].mmPerPoint,
            below: drag.location.y > 0, on: row[n], clearOf: row.indices.filter { $0 != i && $0 != n }.map { row[$0].frame }
        )
        return origin.map { Undock(index: i, host: n, frame: CGRect(origin: $0, size: d.frame.size)) }
    }

    /// `d` beside the row's `end` display at its physical size, bottom-aligned with it, as it joins the row.
    private func docked(_ d: Display, at end: End) -> Display? {
        guard let e = (end == .left ? desk.row.first : desk.row.last)?.display else { return nil }
        var d = d
        d.topMM = e.topMM + e.heightMM - d.heightMM
        return d
    }

    private func canvas(target: CGDirectDisplayID?) -> some View {
        let row = desk.row.map(\.display), stacked = desk.stacked
        let base = frame(row: row, stacked: stacked.map { ($0.screen.display.frame, row[$0.host]) })
        // A stacked display dragged past the row's end previews docked beside it, with the canvas framed to fit.
        let docking = dock(drag, in: base).flatMap { end in
            stacked.first { $0.screen.id == drag?.id }.flatMap { s in docked(s.screen.display, at: end).map { (s, end, $0) } }
        }
        // A row end dragged out past the top or bottom previews stacked on its neighbor, framed the same way.
        let undocking = undock(drag, in: base)
        let others = stacked.filter { $0.screen.id != docking?.0.screen.id }.map { ($0.screen.display.frame, row[$0.host]) }
        let f = docking.map { _, end, d in frame(row: end == .left ? [d] + row : row + [d], stacked: others) }
            ?? undocking.map { u in frame(row: row.indices.filter { $0 != u.index }.map { row[$0] }, stacked: others + [(u.frame, row[u.host])]) }
            ?? base
        let shift = docking.map { $1 == .left ? $2.widthMM : 0 } ?? undocking.map { $0.index == 0 ? -row[0].widthMM : 0 } ?? 0
        let placed = arranged(undocking == nil ? drag : nil, scale: f.scale)
        let slots = lefts(placed.order)
        let rowLefts = desk.row.indices.map { shift + (drag?.id == desk.row[$0].id && undocking == nil ? placed.left : slots[$0]) }
        let guideColor = { (i: Int) in desk.guides && row.count > 1 ? Color(nsColor: GuideOverlay.color(i)) : nil }

        return ZStack(alignment: .topLeading) {
            ForEach(Array(desk.row.enumerated()), id: \.element.id) { i, screen in
                let d = placed.displays[i]
                let dragged = drag?.id == screen.id
                // Lifted out, it's drawn stacked on its neighbor at the neighbor's scale, where it will sit.
                let lifted = undocking.flatMap { u -> (left: CGFloat, top: CGFloat, size: CGSize)? in
                    guard u.index == i else { return nil }
                    let h = row[u.host], s = Arrangement.stack(u.frame, on: h)
                    let size = CGSize(width: u.frame.width * h.mmPerPoint, height: u.frame.height * h.mmPerPoint)
                    return (rowLefts[u.host] + s.leftMM, s.below ? h.topMM + h.heightMM : h.topMM - size.height, size)
                }
                let left = lifted?.left ?? rowLefts[i], top = lifted?.top ?? d.topMM
                let size = lifted?.size ?? CGSize(width: d.widthMM, height: d.heightMM)
                tile(d, name: names[screen.id] ?? "Display", dragged: dragged, selected: screen.id == target, guide: guideColor(i))
                    .frame(width: size.width * f.scale, height: size.height * f.scale)
                    .offset(x: f.inset + left * f.scale, y: (top - f.originMM) * f.scale)
                    .zIndex(dragged ? 1 : 0)
                    .animation(dragged ? nil : .snappy(duration: 0.2), value: placed.order)
                    .onTapGesture { selected = screen.id }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .updating($drag) { value, drag, _ in drag = Drag(id: screen.id, value) }
                            .onEnded {
                                let drag = Drag(id: screen.id, $0)
                                if let u = undock(drag, in: base) { return desk.move(screen.id, to: u.frame.origin) }
                                selected = screen.id
                                commit(drag, scale: f.scale)
                            }
                    )
            }
            ForEach(stacked, id: \.screen.id) { s in
                let d = s.screen.display
                let dragged = drag?.id == s.screen.id
                // Docking, it's drawn at its physical size at the row's end, where it will sit in the row.
                let p = docking.flatMap { docked, end, display in
                    docked.screen.id != s.screen.id ? nil : Placement(
                        left: end == .left ? 0 : row.map(\.widthMM).reduce(0, +), top: display.topMM,
                        size: CGSize(width: display.widthMM, height: display.heightMM), frame: d.frame
                    )
                } ?? place(s, offset: dragged ? drag?.offset : nil, row: placed.displays, lefts: rowLefts, span: f.span, scale: f.scale)
                tile(d, name: names[s.screen.id] ?? "Display", dragged: dragged, selected: false, guide: nil)
                    .frame(width: p.size.width * f.scale, height: p.size.height * f.scale)
                    .offset(x: f.inset + p.left * f.scale, y: (p.top - f.originMM) * f.scale)
                    .zIndex(dragged ? 1 : 0)
                    .animation(dragged ? nil : .snappy(duration: 0.2), value: placed.order)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .updating($drag) { value, drag, _ in drag = Drag(id: s.screen.id, value) }
                            .onEnded { value in
                                let drag = Drag(id: s.screen.id, value)
                                if let end = dock(drag, in: base) { return dockBeside(s, at: end) }
                                let p = place(s, offset: drag.offset, row: placed.displays, lefts: rowLefts, span: f.span, scale: f.scale)
                                if p.frame.origin != d.frame.origin { desk.move(s.screen.id, to: p.frame.origin) }
                            }
                    )
            }
        }
        .frame(width: width, height: f.heightMM * f.scale, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        // The guides follow the displays as arranged, drag included, and leave with the popup.
        .background(OnWindowVisibility { open = $0 })
        .onChange(of: open && desk.guides && row.count > 1 ? placed.displays : nil, initial: true) { _, shown in
            if let shown { GuideOverlay.show(desk.row.map(\.id), shown) } else { GuideOverlay.hide() }
        }
        .onDisappear { GuideOverlay.hide() }
    }

    /// Moves a stacked display beside the row's `end` display in macOS, bottom-aligned with it, and saves its
    /// physical top there, so it joins the row (and the cursor bridge) as previewed.
    private func dockBeside(_ s: Desk.Stacked, at end: End) {
        guard let e = (end == .left ? desk.row.first : desk.row.last)?.display,
              let d = docked(s.screen.display, at: end) else { return }
        let f = s.screen.display.frame
        desk.move(s.screen.id, to: CGPoint(x: end == .left ? e.frame.minX - f.width : e.frame.maxX, y: e.frame.maxY - f.height))
        desk.setTop(d.topMM, of: s.screen.id)
    }

    /// A display's tile: name and diagonal, with `guide`'s color marked when guides are on.
    private func tile(_ d: Display, name: String, dragged: Bool, selected: Bool, guide: Color?) -> some View {
        let inches = Double(hypot(d.widthMM, d.heightMM) / 25.4)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(dragged ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.07))
            .strokeBorder(selected ? Color.accentColor : Color.white.opacity(dragged ? 0.5 : 0.14), lineWidth: selected ? 1.5 : 1)
            .overlay {
                VStack(spacing: 1) {
                    HStack(spacing: 3) {
                        if let guide { Circle().fill(guide).frame(width: 5, height: 5) }
                        Text(name).font(.caption.weight(.semibold))
                    }
                    Text("\(inches.formatted(.number.precision(.fractionLength(0...1))))\"")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(4)
            }
            .padding(1) // a hairline gap between neighbors
            .contentShape(Rectangle())
    }

    /// The displays with the dragged one moved, the left-to-right order (indices into `desk.row`) its
    /// horizontal position gives, and its left edge in mm. Without a drag, the saved arrangement.
    private func arranged(_ drag: Drag?, scale: CGFloat) -> (displays: [Display], order: [Int], left: CGFloat) {
        var displays = desk.row.map(\.display)
        let identity = Array(displays.indices)
        guard let drag, let i = desk.row.firstIndex(where: { $0.id == drag.id }) else { return (displays, identity, 0) }
        // A reorder drag that wobbles less than the snap reach keeps the saved top, and so does one that ends within
        // a point of level, rather than snapping the top to a guide.
        let dx = abs(drag.offset.width), dy = abs(drag.offset.height)
        let sideways = desk.canReorder && dy < Self.snapPoints && dx > dy
        // A display alone in the row has nothing to line up with, so it doesn't move up or down.
        if dy >= 1, !sideways, displays.count > 1 {
            displays[i].topMM = Arrangement.place(
                i, at: displays[i].topMM + drag.offset.height / scale, in: displays,
                snapMM: desk.guides ? Self.snapPoints / scale : nil
            )
        }
        // Without reordering, the display only moves up and down.
        guard desk.canReorder else { return (displays, identity, lefts(identity)[i]) }
        let widths = displays.map(\.widthMM)
        let left = min(max(lefts(identity)[i] + drag.offset.width / scale, 0), widths.reduce(0, +) - widths[i])
        return (displays, Arrangement.order(widths: widths, dragging: i, toLeft: left), left)
    }

    /// A stacked display as drawn, in mm with the row starting at 0, and its frame in macOS (global points).
    private struct Placement {
        let left: CGFloat
        let top: CGFloat
        let size: CGSize
        let frame: CGRect
    }

    /// Where a stacked display sits against its host or, dragged by `offset`, where it lands: along the row (kept
    /// over it, or where it already hangs, and within the canvas `span`), against the display it overlaps most, on
    /// the side its center is on, clear of that display's neighbors. It's drawn at its host's scale from the macOS
    /// frame that results, as the menu shows it once applied.
    private func place(
        _ s: Desk.Stacked, offset: CGSize?, row: [Display], lefts: [CGFloat], span: ClosedRange<CGFloat>, scale: CGFloat
    ) -> Placement {
        let d = s.screen.display
        let size = { (h: Int) in CGSize(width: d.frame.width * row[h].mmPerPoint, height: d.frame.height * row[h].mmPerPoint) }
        let top = { (h: Int, below: Bool) in below ? row[h].topMM + row[h].heightMM : row[h].topMM - size(h).height }
        let base = Arrangement.stack(d.frame, on: row[s.host])
        let left = lefts[s.host] + base.leftMM
        let unmoved = Placement(left: left, top: top(s.host, base.below), size: size(s.host), frame: d.frame)
        guard let offset else { return unmoved }
        let width = size(s.host).width, free = row.map(\.widthMM).reduce(0, +) - width
        let moved = min(
            max(left + offset.width / scale, span.lowerBound, min(0, free, left)),
            span.upperBound - width, max(0, free, left)
        )
        // A drag that's barely sideways keeps its host.
        let h = abs(offset.width) < Self.snapPoints ? s.host
            : Arrangement.host(left: moved, width: width, in: row.indices.map { (lefts[$0], row[$0].widthMM) }) ?? s.host
        let below = top(s.host, base.below) + size(s.host).height / 2 + offset.height / scale > row[h].topMM + row[h].heightMM / 2
        // Where it can't fit, it stays where it was.
        guard let origin = Arrangement.origin(
            stacking: d.frame.size, leftMM: moved - lefts[h], below: below, on: row[h],
            clearOf: row.indices.filter { $0 != h }.map { row[$0].frame }
        ) else { return unmoved }
        let frame = CGRect(origin: origin, size: d.frame.size)
        // The frame can sit mostly on a neighbor of `h`, which it then follows.
        let host = Arrangement.host(of: frame, among: row.map(\.frame)) ?? h
        let landed = Arrangement.stack(frame, on: row[host])
        let placed = Placement(left: lefts[host] + landed.leftMM, top: top(host, landed.below), size: size(host), frame: frame)
        // Sliding clear of a neighbor can push it off the canvas, which counts as not fitting too.
        return span.contains(placed.left + 0.5) && span.contains(placed.left + placed.size.width - 0.5) ? placed : unmoved
    }

    /// Left edge (mm) of each display when laid out in `order`, indexed like `desk.row`.
    private func lefts(_ order: [Int]) -> [CGFloat] {
        var lefts = [CGFloat](repeating: 0, count: order.count)
        var x: CGFloat = 0
        for j in order {
            lefts[j] = x
            x += desk.row[j].display.widthMM
        }
        return lefts
    }

    /// Moves a display by `pixels` of its panel, without snapping, so it can sit just off a guide.
    /// A display alone in the row has nothing to line up with, so it stays put.
    private func nudge(_ id: CGDirectDisplayID, pixels: CGFloat) {
        guard desk.row.count > 1, let i = desk.row.firstIndex(where: { $0.id == id }) else { return }
        let d = desk.row[i].display
        let top = Arrangement.place(i, at: d.topMM + pixels * d.widthMM / CGFloat(nativePixelWidth(id)), in: desk.row.map(\.display))
        if top != d.topMM { desk.setTop(top, of: id) }
    }

    /// The panel's own pixel width, from its native mode. A scaled mode's backing pixels can be smaller or larger.
    private func nativePixelWidth(_ id: CGDirectDisplayID) -> Int {
        let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode]
        return modes?.first { $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 }?.pixelWidth ?? CGDisplayPixelsWide(id)
    }

    private func commit(_ drag: Drag, scale: CGFloat) {
        guard let i = desk.row.firstIndex(where: { $0.id == drag.id }) else { return }
        let placed = arranged(drag, scale: scale)
        withAnimation(.snappy(duration: 0.2)) {
            if placed.displays[i].topMM != desk.row[i].display.topMM { desk.setTop(placed.displays[i].topMM, of: drag.id) }
            if placed.order != Array(placed.displays.indices) { desk.reorder(placed.order.map { desk.row[$0].id }) }
        }
    }
}
