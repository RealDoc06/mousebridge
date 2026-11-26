import BridgeCore
import SwiftUI

/// The side-by-side displays (`Desk.row`) at real scale, as on the desk. Dragging one up or down sets where it physically
/// sits, which the cursor bridge maps crossings by, and the arrows nudge the selected one a pixel at a time.
/// Dragging one past a neighbor reorders macOS's arrangement. With guides on, drags snap to aligned edges and
/// `GuideOverlay` draws the guides on the real displays. Displays stacked above or below the row (`Desk.stacked`)
/// sit against the one they touch, and dragging one moves it along that edge, onto another display, or to the
/// other side, in macOS's arrangement only.
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
    }

    /// Snap reach in points on screen, so it feels the same at any scale.
    private static let snapPoints: CGFloat = 6

    var body: some View {
        // Until one is picked, the arrows move the first display that isn't the main one.
        let target = selected.flatMap { id in desk.row.first { $0.id == id } }?.id
            ?? desk.row.first { $0.id != CGMainDisplayID() }?.id
        Panel {
            Text("Arrangement")
            Spacer()
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
        } content: {
            canvas(target: target)
        }
    }

    private func canvas(target: CGDirectDisplayID?) -> some View {
        let row = desk.row.map(\.display), stacked = desk.stacked
        let rowWidth = row.map(\.widthMM).reduce(0, +)
        // Room for stacked displays hanging past their host's sides, wherever the host moves.
        let overhangs = stacked.map { s in
            let left = Arrangement.stack(s.screen.display.frame, on: row[s.host]).leftMM
            return (left: -left, right: left + s.screen.display.widthMM - row[s.host].widthMM)
        }
        let padLeft = overhangs.map(\.left).reduce(0, max), padRight = overhangs.map(\.right).reduce(0, max)
        let span = -padLeft...(rowWidth + padRight)
        let scale = width / (span.upperBound - span.lowerBound)
        let placed = arranged(drag, scale: scale)
        let slots = lefts(placed.order)
        let rowLefts = desk.row.indices.map { drag?.id == desk.row[$0].id ? placed.left : slots[$0] }
        // Framed on the saved arrangement with room for any drag, so it holds still while one moves. Stacked
        // displays get room above and below, since one can be dragged to either side.
        let bounds = Arrangement.bounds(row)
        let tallest = stacked.map(\.screen.display.heightMM).max() ?? 0
        let originMM = bounds.lowerBound - tallest, heightMM = bounds.upperBound - bounds.lowerBound + 2 * tallest

        return ZStack(alignment: .topLeading) {
            ForEach(Array(desk.row.enumerated()), id: \.element.id) { i, screen in
                let d = placed.displays[i]
                let dragged = drag?.id == screen.id
                tile(d, name: names[screen.id] ?? "Display", dragged: dragged, selected: screen.id == target)
                    .frame(width: d.widthMM * scale, height: d.heightMM * scale)
                    .offset(x: (padLeft + rowLefts[i]) * scale, y: (d.topMM - originMM) * scale)
                    .zIndex(dragged ? 1 : 0)
                    .animation(dragged ? nil : .snappy(duration: 0.2), value: placed.order)
                    .onTapGesture { selected = screen.id }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .updating($drag) { value, drag, _ in drag = Drag(id: screen.id, offset: value.translation) }
                            .onEnded {
                                selected = screen.id
                                commit(Drag(id: screen.id, offset: $0.translation), scale: scale)
                            }
                    )
            }
            ForEach(stacked, id: \.screen.id) { s in
                let d = s.screen.display
                let dragged = drag?.id == s.screen.id
                let p = place(s, offset: dragged ? drag?.offset : nil, row: placed.displays, lefts: rowLefts, span: span, scale: scale)
                tile(d, name: names[s.screen.id] ?? "Display", dragged: dragged, selected: false)
                    .frame(width: d.widthMM * scale, height: d.heightMM * scale)
                    .offset(x: (padLeft + p.left) * scale, y: (p.top - originMM) * scale)
                    .zIndex(dragged ? 1 : 0)
                    .animation(dragged ? nil : .snappy(duration: 0.2), value: placed.order)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .updating($drag) { value, drag, _ in drag = Drag(id: s.screen.id, offset: value.translation) }
                            .onEnded {
                                let p = place(s, offset: $0.translation, row: placed.displays, lefts: rowLefts, span: span, scale: scale)
                                if p.frame.origin != d.frame.origin { desk.move(s.screen.id, to: p.frame.origin) }
                            }
                    )
            }
        }
        .frame(width: width, height: heightMM * scale, alignment: .topLeading)
        // The guides follow the displays as arranged, drag included, and leave with the popup.
        .background(OnWindowVisibility { open = $0 })
        .onChange(of: open && desk.guides ? placed.displays : nil, initial: true) { _, shown in
            if let shown { GuideOverlay.show(desk.row.map(\.id), shown) } else { GuideOverlay.hide() }
        }
        .onDisappear { GuideOverlay.hide() }
    }

    private func tile(_ d: Display, name: String, dragged: Bool, selected: Bool) -> some View {
        let inches = Double(hypot(d.widthMM, d.heightMM) / 25.4)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(dragged ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.07))
            .strokeBorder(selected ? Color.accentColor : Color.white.opacity(dragged ? 0.5 : 0.14), lineWidth: selected ? 1.5 : 1)
            .overlay {
                VStack(spacing: 1) {
                    Text(name).font(.caption.weight(.semibold))
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
        let frame: CGRect
    }

    /// Where a stacked display sits against its host or, dragged by `offset`, where it lands: along the row (kept
    /// over it, or where it already hangs, and within the canvas `span`), against the display it overlaps most, on
    /// the side its center is on. It's drawn from the frame that gives in macOS, the way the menu shows it after.
    private func place(
        _ s: Desk.Stacked, offset: CGSize?, row: [Display], lefts: [CGFloat], span: ClosedRange<CGFloat>, scale: CGFloat
    ) -> Placement {
        let d = s.screen.display
        let top = { (h: Int, below: Bool) in below ? row[h].topMM + row[h].heightMM : row[h].topMM - d.heightMM }
        let base = Arrangement.stack(d.frame, on: row[s.host])
        let left = lefts[s.host] + base.leftMM
        guard let offset else { return Placement(left: left, top: top(s.host, base.below), frame: d.frame) }
        let free = row.map(\.widthMM).reduce(0, +) - d.widthMM
        let moved = min(
            max(left + offset.width / scale, span.lowerBound, min(0, free, left)),
            span.upperBound - d.widthMM, max(0, free, left)
        )
        let h = Arrangement.host(left: moved, width: d.widthMM, in: row.indices.map { (lefts[$0], row[$0].widthMM) }) ?? s.host
        let below = top(s.host, base.below) + d.heightMM / 2 + offset.height / scale > row[h].topMM + row[h].heightMM / 2
        let frame = CGRect(
            origin: Arrangement.origin(stacking: d.frame.size, leftMM: moved - lefts[h], below: below, on: row[h]),
            size: d.frame.size
        )
        // At a different scale in points, the frame can sit mostly on a neighbor of `h`, which it then follows.
        let host = Arrangement.host(of: frame, among: row.map(\.frame)) ?? h
        let landed = Arrangement.stack(frame, on: row[host])
        return Placement(left: lefts[host] + landed.leftMM, top: top(host, landed.below), frame: frame)
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
    private func nudge(_ id: CGDirectDisplayID, pixels: CGFloat) {
        guard let i = desk.row.firstIndex(where: { $0.id == id }) else { return }
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
