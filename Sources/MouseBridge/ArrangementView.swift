import BridgeCore
import SwiftUI

/// The side-by-side displays (`Desk.row`) at real scale, as on the desk. Dragging one up or down sets where it physically
/// sits, which the cursor bridge maps crossings by. Dragging it past a neighbor reorders macOS's arrangement.
/// With guides on, edges that line up get a yellow line and drags snap to them.
struct ArrangementView: View {
    let desk: Desk
    /// Label for each display, by display ID.
    let names: [CGDirectDisplayID: String]
    let width: CGFloat

    /// Resets by itself when a drag ends or is cancelled, e.g. by the popup closing.
    @GestureState private var drag: Drag?

    private struct Drag: Equatable {
        let id: CGDirectDisplayID
        var offset: CGSize
    }

    /// Snap reach in points on screen, so it feels the same at any scale.
    private static let snapPoints: CGFloat = 6

    var body: some View {
        let scale = width / desk.row.map(\.display.widthMM).reduce(0, +)
        let placed = arranged(drag, scale: scale)
        let slots = lefts(placed.order)
        // Framed on the saved arrangement with room for any drag, so it holds still while one moves.
        let bounds = Arrangement.bounds(desk.row.map(\.display))
        let originMM = bounds.lowerBound, heightMM = bounds.upperBound - bounds.lowerBound

        ZStack(alignment: .topLeading) {
            ForEach(Array(desk.row.enumerated()), id: \.element.id) { i, screen in
                let d = placed.displays[i]
                let dragged = drag?.id == screen.id
                tile(d, name: names[screen.id] ?? "Display", dragged: dragged)
                    .frame(width: d.widthMM * scale, height: d.heightMM * scale)
                    .offset(x: (dragged ? placed.left : slots[i]) * scale, y: (d.topMM - originMM) * scale)
                    .zIndex(dragged ? 1 : 0)
                    .animation(dragged ? nil : .snappy(duration: 0.2), value: placed.order)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .updating($drag) { value, drag, _ in drag = Drag(id: screen.id, offset: value.translation) }
                            .onEnded { commit(Drag(id: screen.id, offset: $0.translation), scale: scale) }
                    )
            }
            if desk.guides {
                ForEach(Arrangement.guides(placed.displays), id: \.self) { mm in
                    Rectangle().fill(.yellow)
                        .frame(width: width, height: 1)
                        .offset(y: (mm - originMM) * scale - 0.5)
                        .zIndex(2)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, height: heightMM * scale, alignment: .topLeading)
    }

    private func tile(_ d: Display, name: String, dragged: Bool) -> some View {
        let inches = Double(hypot(d.widthMM, d.heightMM) / 25.4)
        return RoundedRectangle(cornerRadius: 4)
            .fill(dragged ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12))
            .strokeBorder(Color.primary.opacity(dragged ? 0.6 : 0.25))
            .overlay {
                VStack(spacing: 1) {
                    Text(name).font(.caption.weight(.medium))
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
        if dy >= 1, !sideways {
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

    private func commit(_ drag: Drag, scale: CGFloat) {
        guard let i = desk.row.firstIndex(where: { $0.id == drag.id }) else { return }
        let placed = arranged(drag, scale: scale)
        withAnimation(.snappy(duration: 0.2)) {
            if placed.displays[i].topMM != desk.row[i].display.topMM { desk.setTop(placed.displays[i].topMM, of: drag.id) }
            if placed.order != Array(placed.displays.indices) { desk.reorder(placed.order.map { desk.row[$0].id }) }
        }
    }
}
